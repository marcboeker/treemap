// Live updates: watches the session root with FSEvents and rescans the nodes that changed.
//
// Pipeline: FSEvents (directory-level, ~1 s latency) -> pending set of paths -> debounce ->
// map each path to the nearest existing ancestor node inside the root -> one
// `ScanSession.rescan` of all of them (it drops nodes that sit below another one). Events that arrive while the
// initial scan still runs are kept and handled when the scan has finished.
//
// Paths under a mount point (other volume) are ignored: the session never entered them.

import CoreServices
import Darwin
import Foundation
import Synchronization

public final class FileWatcher: Sendable {
    public enum Event: Sendable, Hashable {
        /// A batch of rescans ended; the tree changed. Ask for a new layout.
        case updated
        /// The root itself is gone or was moved. The App decides what to do (close the window).
        case rootGone
    }

    public let events: AsyncStream<Event>

    private let session: ScanSession
    private let debounce: Duration
    private let latency: Double
    private let continuation: AsyncStream<Event>.Continuation
    private let wake: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    private struct StreamBox: @unchecked Sendable { let ref: FSEventStreamRef }

    private struct Pending {
        var paths: Set<String> = []
        var rootChanged = false
        var rescanAll = false
    }
    private struct State {
        var stream: StreamBox?
        var task: Task<Void, Never>?
        var pending = Pending()
        var started = false
        var stopped = false
    }
    private let state = Mutex(State())

    /// - Parameters:
    ///   - debounce: quiet time after the first event of a batch before the rescans start.
    ///   - latency: FSEvents coalescing latency in seconds.
    public init(session: ScanSession, debounce: Duration = .milliseconds(400), latency: Double = 1.0) {
        self.session = session
        self.debounce = debounce
        self.latency = latency
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))
        (wake, wakeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit { stop() }

    /// Starts watching (once). Safe to call before the initial scan ended.
    public func start() {
        let go: Bool = state.withLock { s in
            if s.started || s.stopped { return false }
            s.started = true
            return true
        }
        guard go else { return }

        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: CFArray.self) as? [String] ?? []
            var batch: [(String, UInt32)] = []
            batch.reserveCapacity(count)
            for i in 0..<min(count, paths.count) { batch.append((paths[i], eventFlags[i])) }
            watcher.receive(batch)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [session.rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            Unmanaged.passUnretained(self).release()
            return
        }
        let queue = DispatchQueue(label: "treemap.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        let task = Task.detached(priority: .utility) { [self] in
            await session.waitUntilFinished()
            for await _ in wake {
                if Task.isCancelled { break }
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { break }
                await processPending()
            }
        }
        state.withLock { s in
            s.stream = StreamBox(ref: stream)
            s.task = task
        }
    }

    /// Stops watching and ends `events`.
    public func stop() {
        let (stream, task, wasStarted): (StreamBox?, Task<Void, Never>?, Bool) = state.withLock { s in
            if s.stopped { return (nil, nil, false) }
            s.stopped = true
            let r = (s.stream, s.task, s.started && s.stream != nil)
            s.stream = nil
            s.task = nil
            return r
        }
        if let stream {
            FSEventStreamStop(stream.ref)
            FSEventStreamInvalidate(stream.ref)
            FSEventStreamRelease(stream.ref)
        }
        if wasStarted { Unmanaged.passUnretained(self).release() }
        task?.cancel()
        wakeContinuation.finish()
        continuation.finish()
    }

    // MARK: Events

    private func receive(_ batch: [(String, UInt32)]) {
        var touched = false
        state.withLock { s in
            for (path, flags) in batch {
                if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    s.pending.rootChanged = true
                    touched = true
                    continue
                }
                if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                    || flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 {
                    // Events were lost: we cannot know what changed below this path.
                    if path == session.rootPath || path.isEmpty { s.pending.rescanAll = true }
                }
                s.pending.paths.insert(path)
                touched = true
            }
        }
        if touched { wakeContinuation.yield() }
    }

    /// Takes the pending set and rescans. Internal so tests can drive it.
    func processPending() async {
        let p: Pending = state.withLock { s in
            defer { s.pending = Pending() }
            return s.pending
        }
        if p.rootChanged {
            var st = stat()
            if stat(session.rootPath, &st) != 0 {
                continuation.yield(.rootGone)
                return
            }
        }
        var targets: Set<NodeID> = []
        if p.rescanAll || p.rootChanged {
            targets.insert(session.rootID)
        } else {
            for path in p.paths {
                if let id = nearestNode(for: path) { targets.insert(id) }
            }
        }
        guard !targets.isEmpty, !Task.isCancelled else { return }
        await session.rescan(Array(targets))
        if Task.isCancelled { return }
        continuation.yield(.updated)
    }

    /// The deepest node of the tree that is `path` or one of its ancestors. nil for paths
    /// outside the root and for anything at or below a mount point. FSEvents reports resolved
    /// paths (/private/var/...); the session accepts both forms.
    func nearestNode(for path: String) -> NodeID? {
        guard let (id, flags) = session.deepestNodeAndFlags(atPath: path), !flags.contains(.mountPoint)
        else { return nil }
        return id
    }
}
