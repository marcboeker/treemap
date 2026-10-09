// A scan session: owns the tree, the walk and the event stream of one root.
//
// Design: a `final class` instead of an actor. The walk runs on plain OS threads that
// publish into the tree under a mutex; an actor would only add an executor hop for every
// batch and make cheap reads (hover -> info(_:)) asynchronous. All state is behind a
// `Mutex` or an atomic, so every method can be called from any thread, and the App can
// call the read APIs synchronously. Only `rescan` is `async` (it waits for a walk).
//
// Volume rules: the walk stays on the root's volume. A directory on
// another device, flagged as mount point or as automount trigger becomes a `.mountPoint`
// leaf. Scanning "/" on a modern macOS shows the Data volume through APFS firmlinks
// (/Users, /Applications, ...) and again under /System/Volumes/Data. We count it once:
// when the root is "/", /System/Volumes/Data is never entered (it becomes a mount-point
// leaf of size 0) and the firmlinked directories are walked normally. Content that lives
// only on the Data volume and has no firmlink is not counted, like in Finder's "Macintosh HD".

import CoreGraphics
import Darwin
import Foundation
import Synchronization

public final class ScanSession: Sendable {
    /// Normalized root path (no trailing slash). Node paths are built from it.
    public let rootPath: String
    /// `realpath` of the root (e.g. /private/var/... for /var/...); FSEvents reports these.
    public let rootRealPath: String
    public let rootID = NodeID(raw: 0)
    public let events: AsyncStream<SessionEvent>

    private let box: TreeBox
    private let counters = Counters()
    private let rules: WalkRules
    private let workerCount: Int
    /// Subtree rescans are small; more threads only add contention.
    private static let rescanWorkerLimit = 4
    private let continuation: AsyncStream<SessionEvent>.Continuation

    private struct State {
        var run: ScanRun?
        var started = false
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var lastEmittedGeneration: UInt64 = .max
    }
    private let state = Mutex(State())

    public init(root: URL, workerCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        let path = PathUtil.normalized(root.standardizedFileURL.path)
        self.rootPath = path
        if let r = realpath(path, nil) {
            rootRealPath = String(cString: r)
            free(r)
        } else {
            rootRealPath = path
        }
        self.workerCount = max(1, workerCount)
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .bufferingNewest(64))

        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        var st = stat()
        var devices = Set<Int32>()
        var skip = Set<String>()
        let tree: Tree
        var done = true
        if stat(path, &st) != 0 {
            counters.errors.store(1, ordering: .relaxed)
            tree = Tree(rootName: name, flags: [.directory, .unreadable], scanning: false)
        } else if st.isDirectory {
            done = false
            devices.insert(st.st_dev)
            if path == "/" {
                var data = stat()
                if stat("/System/Volumes/Data", &data) == 0 { devices.insert(data.st_dev) }
                skip.insert("/System/Volumes/Data")
            }
            tree = Tree(rootName: name, flags: .directory, mtime: st.mtimeSeconds, scanning: true)
        } else {
            counters.files.store(1, ordering: .relaxed)
            counters.bytes.store(st.allocatedBytes, ordering: .relaxed)
            tree = .leaf(named: name, stat: st)
        }
        rules = WalkRules(allowedDevices: devices, skipPaths: skip)
        box = TreeBox(tree)
        state.withLock { $0.finished = done }
    }

    // MARK: Lifecycle

    /// Starts the walk (once). Emits events on `events`.
    public func start() {
        let alreadyDone: Bool = state.withLock { s in
            if s.started { return true }
            s.started = true
            if s.finished { return true }
            let run = ScanRun(box: box, counters: counters, rules: rules, workerCount: workerCount)
            s.run = run
            counters.directories.add(1, ordering: .relaxed)
            run.start(roots: [(rootID.raw, rootPath)]) { [self] in finish() }
            return false
        }
        if alreadyDone {
            finish()
            return
        }
        Task.detached(priority: .utility) { [self] in
            while !state.withLock({ $0.finished }) {
                try? await Task.sleep(for: .milliseconds(100))
                emitIfChanged()
            }
        }
    }

    /// Stops the walk. Directories not finished keep `.scanning`. `events` ends with `.finished`.
    public func cancel() {
        state.withLock { $0.run }?.cancel()
    }

    /// Takes the work for the subtree of `id` before all other queued work.
    public func prioritize(_ id: NodeID) {
        guard let path = path(of: id), let run = state.withLock({ $0.run }) else { return }
        run.prioritize(path: path)
    }

    /// Suspends until the walk ended.
    public func waitUntilFinished() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready: Bool = state.withLock { s in
                if s.finished && s.started { return true }
                s.waiters.append(c)
                return false
            }
            if ready { c.resume() }
        }
    }

    private func finish() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.finished = true
            defer { s.waiters = [] }
            return s.waiters
        }
        emitChanged(force: true)
        continuation.yield(.progress(progress))
        continuation.yield(.finished)
        continuation.finish()
        for w in waiters { w.resume() }
    }

    private func emitIfChanged() {
        emitChanged(force: false)
        continuation.yield(.progress(progress))
    }

    private func emitChanged(force: Bool) {
        let gen = box.state.withLock { $0.generation }
        let send: Bool = state.withLock { s in
            if !force && s.lastEmittedGeneration == gen { return false }
            s.lastEmittedGeneration = gen
            return true
        }
        if send { continuation.yield(.changed) }
    }

    // MARK: Reads (synchronous, any thread)

    public var progress: ScanProgress {
        var p = counters.snapshot()
        p.finished = state.withLock { $0.finished }
        return p
    }

    /// Layout of the subtree `viewRoot` (the session root when the id is unknown or removed).
    public func layout(viewRoot: NodeID, bounds: CGRect, options: LayoutOptions = LayoutOptions()) -> TreemapLayout {
        box.state.withLock { tree in
            let root = tree.isAlive(viewRoot.raw) ? viewRoot : rootID
            return TreemapLayouter.layout(tree: tree, root: root, bounds: bounds, options: options)
        }
    }

    /// True while `id` is part of the tree (not removed, not replaced by a rescan of an ancestor).
    public func isAlive(_ id: NodeID) -> Bool {
        box.state.withLock { $0.isAlive(id.raw) }
    }

    /// `id` itself when it is alive, else its closest ancestor that still is.
    public func nearestLiveAncestor(of id: NodeID) -> NodeID? {
        box.state.withLock { t in t.nearestLive(id.raw).map { NodeID(raw: $0) } }
    }

    public func info(_ id: NodeID) -> NodeInfo? {
        box.state.withLock { t in
            guard t.isAlive(id.raw) else { return nil }
            let i = Int(id.raw)
            let p = t.parent[i]
            return NodeInfo(
                id: id, name: t.nameString(id.raw), path: t.path(of: id.raw, rootPath: rootPath),
                size: t.size[i], itemCount: Int64(t.items[i]),
                dirCount: Int64(t.dirs[i]), unreadableCount: Int64(t.unreadable[i]),
                modified: Date(timeIntervalSince1970: TimeInterval(t.mtime[i])),
                flags: CellFlags(rawValue: t.flags[i] & Tree.publicMask),
                parent: p == Tree.none ? nil : NodeID(raw: p))
        }
    }

    public func path(of id: NodeID) -> String? {
        box.state.withLock { t in t.isAlive(id.raw) ? t.path(of: id.raw, rootPath: rootPath) : nil }
    }

    /// Ids from the session root down to `id`, both included (breadcrumb order).
    public func ancestors(of id: NodeID) -> [NodeID] {
        box.state.withLock { t in
            guard t.isAlive(id.raw) else { return [] }
            var out: [NodeID] = []
            var cur = id.raw
            while cur != Tree.none { out.append(NodeID(raw: cur)); cur = t.parent[Int(cur)] }
            return out.reversed()
        }
    }

    /// Looks up an absolute path inside the tree; nil when it is not part of it.
    public func node(atPath path: String) -> NodeID? {
        guard let rel = PathUtil.relative(PathUtil.normalized(path), to: rootPath) else { return nil }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true)
        if comps.isEmpty { return rootID }
        return box.state.withLock { t in
            var cur: UInt32 = 0
            for c in comps {
                guard let next = t.child(of: cur, named: String(c)) else { return nil }
                cur = next
            }
            return NodeID(raw: cur)
        }
    }

    /// The deepest node on the way from the root to `path`: `path` itself when it is in the
    /// tree, else its closest ancestor that is. The descent stops at a mount point. `path` may
    /// start with `rootPath` or `rootRealPath`; nil for paths outside the root.
    func deepestNodeAndFlags(atPath path: String) -> (id: NodeID, flags: CellFlags)? {
        let p = PathUtil.normalized(path)
        guard let rel = PathUtil.relative(p, to: rootPath) ?? PathUtil.relative(p, to: rootRealPath)
        else { return nil }
        let mount = CellFlags.mountPoint.rawValue
        return box.state.withLock { t in
            var cur: UInt32 = 0
            for c in rel.utf8.split(separator: UInt8(ascii: "/")) {
                guard t.flags[Int(cur)] & mount == 0, let next = t.child(of: cur, nameBytes: c) else { break }
                cur = next
            }
            return (NodeID(raw: cur), CellFlags(rawValue: t.flags[Int(cur)] & Tree.publicMask))
        }
    }

    /// Drops every id that lies below another id of the set, and ids no longer alive.
    /// Result is unique and ordered shallowest first.
    public func topLevel(_ ids: [NodeID]) -> [NodeID] {
        let set = Set(ids.map(\.raw))
        let out: [(depth: Int, id: NodeID)] = box.state.withLock { t in
            var out: [(depth: Int, id: NodeID)] = []
            for raw in set where t.isAlive(raw) {
                var depth = 0
                var cur = t.parent[Int(raw)]
                var covered = false
                while cur != Tree.none {
                    if set.contains(cur) { covered = true; break }
                    depth += 1
                    cur = t.parent[Int(cur)]
                }
                if !covered { out.append((depth, NodeID(raw: raw))) }
            }
            return out
        }
        return out.sorted { $0.depth < $1.depth }.map(\.id)
    }

    /// Direct children, largest first.
    public func children(of id: NodeID) -> [NodeID] {
        box.state.withLock { t in
            guard t.isAlive(id.raw) else { return [] }
            return t.childIDs(id.raw).sorted { t.size[Int($0)] > t.size[Int($1)] }.map { NodeID(raw: $0) }
        }
    }

    // MARK: Mutations

    /// Drops nodes the App has trashed; sizes of the ancestors shrink. The root cannot be removed.
    /// Returns the ids that were removed.
    @discardableResult
    public func remove(_ ids: [NodeID]) -> [NodeID] {
        let removed: [NodeID] = box.state.withLock { t in
            ids.filter { t.remove($0.raw) }
        }
        if !removed.isEmpty { emitChanged(force: true) }
        return removed
    }

    /// Walks the subtrees of `ids` again, in one parallel walk, and swaps each in; ancestors get
    /// the size delta. Every node that still exists keeps its id; only new entries get new ids.
    /// A path that vanished removes its node. Ids below another id of the list are skipped.
    public func rescan(_ ids: [NodeID]) async {
        let targets = topLevel(ids)
        guard !targets.isEmpty else { return }
        let (entries, seed) = box.state.withLock { t in
            // Mount points are other volumes: leave them out.
            (targets.filter { !t.flags(of: $0).contains(.mountPoint) }
                .map { (id: $0, path: t.path(of: $0.raw, rootPath: rootPath), name: t.nameString($0.raw)) },
             t.linksForRescan(of: targets.map(\.raw)))
        }

        var gone: [NodeID] = []
        var leaves: [(id: NodeID, tree: Tree)] = []
        var walks: [(id: NodeID, path: String)] = []
        // All directories are walked into one side tree: a synthetic node 0 with one child per target.
        var batch = Batch()
        for e in entries {
            var st = stat()
            if stat(e.path, &st) != 0 {
                if e.id != rootID { gone.append(e.id) }
            } else if !st.isDirectory {
                leaves.append((e.id, .leaf(named: e.name, stat: st)))
            } else {
                let bytes = Array(e.name.utf8)
                batch.entries.append(Batch.Entry(
                    nameOffset: UInt32(batch.names.count), nameLength: UInt16(bytes.count), kind: .walk,
                    multiLink: false, size: 0, mtime: st.mtimeSeconds, dev: st.st_dev, ino: 0))
                batch.names.append(contentsOf: bytes)
                walks.append((e.id, e.path))
            }
        }

        var side: Tree?
        var sideRoots: [UInt32] = []
        if !walks.isEmpty {
            var tree = Tree(rootName: "", flags: .directory, scanning: false, links: seed)
            sideRoots = tree.publish(dir: 0, batch: batch, final: false)!.dirIDs
            let sideBox = TreeBox(tree)
            let run = ScanRun(box: sideBox, counters: Counters(), rules: rules,
                              workerCount: min(workerCount, Self.rescanWorkerLimit))
            let roots = zip(sideRoots, walks).map { (id: $0, path: $1.path) }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    run.start(roots: roots) { c.resume() }
                }
            } onCancel: {
                run.cancel()
            }
            if run.isCancelled || Task.isCancelled { return }
            side = sideBox.state.withLock { $0 }
        }
        box.state.withLock { t in
            if let side {
                for (r, w) in zip(sideRoots, walks) { t.graft(side, from: r, onto: w.id.raw) }
            }
            for l in leaves { t.graft(l.tree, onto: l.id.raw) }
            for g in gone { t.remove(g.raw) }
        }
        emitChanged(force: true)
    }
}

// MARK: stat helpers

extension stat {
    var isDirectory: Bool { st_mode & S_IFMT == S_IFDIR }
    /// Allocated bytes (`st_blocks` are 512-byte units).
    var allocatedBytes: Int64 { Int64(st_blocks) * 512 }
    var mtimeSeconds: Int64 { Int64(st_mtimespec.tv_sec) }
}

extension Tree {
    /// One-node tree for a non-directory root.
    static func leaf(named name: String, stat st: stat) -> Tree {
        Tree(rootName: name, flags: [], size: st.allocatedBytes, mtime: st.mtimeSeconds, scanning: false)
    }
}
