// One parallel walk. Worker threads (plain OS threads: the work is blocking syscalls and
// must not occupy Swift's cooperative pool) pull directory tasks from a two-level queue,
// read each directory with getattrlistbulk and publish the entries into a `TreeBox`.

import Darwin
import Foundation
import Synchronization

/// Live counters shared by the walk and the session.
final class Counters: Sendable {
    let files = Atomic<Int64>(0)
    let directories = Atomic<Int64>(0)
    let errors = Atomic<Int64>(0)
    let bytes = Atomic<Int64>(0)
    let current = Mutex<String>("")

    func snapshot() -> ScanProgress {
        var p = ScanProgress()
        p.files = files.load(ordering: .relaxed)
        p.directories = directories.load(ordering: .relaxed)
        p.errors = errors.load(ordering: .relaxed)
        p.bytes = bytes.load(ordering: .relaxed)
        p.currentPath = current.withLock { $0 }
        return p
    }
}

/// Which directories a walk may enter.
struct WalkRules: Sendable {
    /// Devices (st_dev) that count as "the root's volume".
    var allowedDevices: Set<Int32>
    /// Paths that are never entered (they become `.mountPoint` leaves), keyed by parent path:
    /// a worker looks up its directory once and then compares raw name bytes per entry.
    private(set) var skipNames: [String: [[UInt8]]] = [:]

    init(allowedDevices: Set<Int32>, skipPaths: Set<String>) {
        self.allowedDevices = allowedDevices
        for raw in skipPaths {
            let path = PathUtil.normalized(raw)
            let u = path.utf8
            guard path != "/", let cut = u.lastIndex(of: UInt8(ascii: "/")) else { continue }
            let parent = cut == u.startIndex ? "/" : String(path[..<cut])
            skipNames[parent, default: []].append(Array(u[u.index(after: cut)...]))
        }
    }
}

final class ScanRun: @unchecked Sendable {
    struct WalkTask {
        var id: UInt32
        var path: String
        var priority: Bool
    }

    private let box: TreeBox
    private let counters: Counters
    private let rules: WalkRules
    private let workerCount: Int
    private let cancelFlag = Atomic<Bool>(false)

    // Guarded by `cond`.
    private let cond = NSCondition()
    private var normal: [WalkTask] = []
    private var normalHead = 0
    private var priorityStack: [WalkTask] = []
    private var priorityPrefixes: [String] = []
    private var outstanding = 0
    private var liveWorkers = 0
    private var onFinish: (@Sendable () -> Void)?

    init(box: TreeBox, counters: Counters, rules: WalkRules, workerCount: Int) {
        self.box = box
        self.counters = counters
        self.rules = rules
        self.workerCount = max(1, workerCount)
    }

    var isCancelled: Bool { cancelFlag.load(ordering: .relaxed) }

    /// Starts the workers on one or more directories (`id` in the box's tree, absolute path);
    /// `onFinish` runs once on a worker thread after the last one stopped (completed or cancelled).
    func start(roots: [(id: UInt32, path: String)], onFinish: @escaping @Sendable () -> Void) {
        cond.lock()
        self.onFinish = onFinish
        for r in roots { normal.append(WalkTask(id: r.id, path: r.path, priority: false)) }
        outstanding = roots.count
        liveWorkers = workerCount
        cond.unlock()
        for _ in 0..<workerCount {
            let t = Thread { [self] in workerMain() }
            t.qualityOfService = .userInitiated
            t.stackSize = 1 << 20
            t.start()
        }
    }

    func cancel() {
        cancelFlag.store(true, ordering: .relaxed)
        cond.lock()
        normal.removeAll(); normalHead = 0
        priorityStack.removeAll()
        cond.broadcast()
        cond.unlock()
    }

    /// Moves queued work below `path` to the front: it is taken before everything else.
    func prioritize(path: String) {
        cond.lock()
        defer { cond.unlock() }
        priorityPrefixes.append(path)
        if priorityPrefixes.count > 16 { priorityPrefixes.removeFirst() }
        var moved: [WalkTask] = []
        var rest: [WalkTask] = []
        rest.reserveCapacity(normal.count - normalHead)
        for t in normal[normalHead...] {
            if PathUtil.isSelfOrDescendant(t.path, of: path) { moved.append(t) } else { rest.append(t) }
        }
        normal = rest
        normalHead = 0
        // Stack pops from the end: push deepest first so the shallowest pops first.
        moved.sort { $0.path.utf8.count > $1.path.utf8.count }
        for var t in moved { t.priority = true; priorityStack.append(t) }
        // Tasks already in the stack stay below the new ones (newest request wins).
        cond.broadcast()
    }

    // MARK: Queue

    private func dequeue() -> WalkTask? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if isCancelled { return nil }
            if let t = priorityStack.popLast() { return t }
            if normalHead < normal.count {
                let t = normal[normalHead]
                normalHead += 1
                if normalHead > 4096 && normalHead * 2 > normal.count {
                    normal.removeFirst(normalHead)
                    normalHead = 0
                }
                return t
            }
            if outstanding == 0 { return nil }
            cond.wait()
        }
    }

    private func enqueue(_ tasks: [WalkTask], parentIsPriority: Bool) {
        if tasks.isEmpty { return }
        cond.lock()
        for var t in tasks {
            if !t.priority {
                t.priority = parentIsPriority
                    || priorityPrefixes.contains { PathUtil.isSelfOrDescendant(t.path, of: $0) }
            }
            if t.priority { priorityStack.append(t) } else { normal.append(t) }
        }
        outstanding += tasks.count
        if tasks.count > 1 { cond.broadcast() } else { cond.signal() }
        cond.unlock()
    }

    private func taskDone() {
        cond.lock()
        outstanding -= 1
        if outstanding == 0 { cond.broadcast() }
        cond.unlock()
    }

    // MARK: Workers

    private static let bufferSize = 256 * 1024
    private static let flushThreshold = 4096
    /// Minimum time between two status-path updates of one worker. The status is read at ~10 Hz.
    private static let statusIntervalNs: UInt64 = 50_000_000

    private func workerMain() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        var nextStatus: UInt64 = 0
        while let task = dequeue() {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if now >= nextStatus {
                counters.current.withLock { $0 = task.path }
                nextStatus = now + Self.statusIntervalNs
            }
            process(task, buffer: buffer)
            taskDone()
        }
        buffer.deallocate()
        cond.lock()
        liveWorkers -= 1
        let last = liveWorkers == 0
        let finish = onFinish
        cond.unlock()
        if last { finish?() }
    }

    private func process(_ task: WalkTask, buffer: UnsafeMutableRawPointer) {
        let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 {
            counters.errors.add(1, ordering: .relaxed)
            box.state.withLock { $0.markUnreadable(task.id, final: true) }
            return
        }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = UInt16(5)
        attrs.commonattr = A.cmnReturned | A.cmnName | A.cmnDevID | A.cmnObjType | A.cmnModTime | A.cmnFileID | A.cmnError
        attrs.dirattr = A.dirMountStatus
        attrs.fileattr = A.fileLinkCount | A.fileAllocSize

        let skip = rules.skipNames.isEmpty ? nil : rules.skipNames[task.path]
        var batch = Batch()
        var failed = false
        while true {
            if isCancelled { return }
            let n = getattrlistbulk(fd, &attrs, buffer, Self.bufferSize, 0)
            if n < 0 {
                if errno == EINTR { continue }
                failed = true
                break
            }
            if n == 0 { break }
            parse(buffer, count: Int(n), skip: skip, into: &batch)
            if batch.entries.count >= Self.flushThreshold {
                flush(&batch, task: task, final: false)
            }
        }
        if failed { counters.errors.add(1, ordering: .relaxed) }
        flush(&batch, task: task, final: !failed)
        if failed { box.state.withLock { $0.markUnreadable(task.id, final: true) } }
    }

    private func flush(_ batch: inout Batch, task: WalkTask, final: Bool) {
        defer { batch = Batch() }
        let b = batch
        guard let r = box.state.withLock({ $0.publish(dir: task.id, batch: b, final: final) }) else { return }
        counters.files.add(r.files, ordering: .relaxed)
        counters.directories.add(r.dirs, ordering: .relaxed)
        counters.bytes.add(r.bytes, ordering: .relaxed)
        if r.dirIDs.isEmpty { return }
        var tasks: [WalkTask] = []
        tasks.reserveCapacity(r.dirIDs.count)
        var k = 0
        for e in b.entries where e.kind == .walk {
            let name = String(decoding: b.names[Int(e.nameOffset)..<Int(e.nameOffset) + Int(e.nameLength)], as: UTF8.self)
            tasks.append(WalkTask(id: r.dirIDs[k], path: PathUtil.join(task.path, name), priority: false))
            k += 1
        }
        enqueue(tasks, parentIsPriority: task.priority)
    }

    // MARK: getattrlistbulk parsing

    private enum A {
        static let cmnName: UInt32 = 0x0000_0001
        static let cmnDevID: UInt32 = 0x0000_0002
        static let cmnObjType: UInt32 = 0x0000_0008
        static let cmnModTime: UInt32 = 0x0000_0400
        static let cmnFileID: UInt32 = 0x0200_0000
        static let cmnError: UInt32 = 0x2000_0000
        static let cmnReturned: UInt32 = 0x8000_0000
        static let dirMountStatus: UInt32 = 0x0000_0004
        static let fileLinkCount: UInt32 = 0x0000_0001
        static let fileAllocSize: UInt32 = 0x0000_0004
        static let mountPointFlag: UInt32 = 0x1
        static let mountTriggerFlag: UInt32 = 0x2
        static let vreg: UInt32 = 1, vdir: UInt32 = 2
    }

    /// `skip`: names in this directory that are never entered (see `WalkRules.skipNames`).
    private func parse(_ buffer: UnsafeMutableRawPointer, count: Int, skip: [[UInt8]]?, into batch: inout Batch) {
        var p = UnsafeRawPointer(buffer)
        for _ in 0..<count {
            let entryLength = Int(p.loadUnaligned(as: UInt32.self))
            defer { p += entryLength }
            let retCommon = p.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let retDir = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let retFile = p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            var f = p + 24
            var nameStart: UnsafeRawPointer?
            var nameLen = 0
            var dev: Int32 = 0
            var objType: UInt32 = 0
            var mtime: Int64 = 0
            var ino: UInt64 = 0
            var err: UInt32 = 0
            var mountStatus: UInt32 = 0
            var nlink: UInt32 = 1
            var alloc: Int64 = 0
            // getattrlistbulk(2): ATTR_CMN_ERROR comes right after RETURNED_ATTRS, before NAME.
            if retCommon & A.cmnError != 0 { err = f.loadUnaligned(as: UInt32.self); f += 4 }
            if retCommon & A.cmnName != 0 {
                let off = Int(f.loadUnaligned(as: Int32.self))
                nameLen = max(0, Int(f.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) - 1)
                nameStart = f + off
                f += 8
            }
            if retCommon & A.cmnDevID != 0 { dev = f.loadUnaligned(as: Int32.self); f += 4 }
            if retCommon & A.cmnObjType != 0 { objType = f.loadUnaligned(as: UInt32.self); f += 4 }
            if retCommon & A.cmnModTime != 0 { mtime = f.loadUnaligned(as: Int64.self); f += 16 }
            if retCommon & A.cmnFileID != 0 { ino = f.loadUnaligned(as: UInt64.self); f += 8 }
            if retDir & A.dirMountStatus != 0 { mountStatus = f.loadUnaligned(as: UInt32.self); f += 4 }
            if retFile & A.fileLinkCount != 0 { nlink = f.loadUnaligned(as: UInt32.self); f += 4 }
            if retFile & A.fileAllocSize != 0 { alloc = f.loadUnaligned(as: Int64.self); f += 8 }

            guard let nameStart, nameLen > 0, nameLen <= 1023 else { continue }
            if err != 0 {
                counters.errors.add(1, ordering: .relaxed)
                continue
            }
            let nameBytes = UnsafeRawBufferPointer(start: nameStart, count: nameLen)
            let offset = UInt32(batch.names.count)
            batch.names.append(contentsOf: nameBytes)

            var kind = Batch.Kind.file
            if objType == A.vdir {
                kind = .walk
                if mountStatus & (A.mountPointFlag | A.mountTriggerFlag) != 0 || !rules.allowedDevices.contains(dev) {
                    kind = .mount
                } else if let skip, skip.contains(where: { $0.elementsEqual(nameBytes) }) {
                    kind = .mount
                }
            }
            batch.entries.append(Batch.Entry(
                nameOffset: offset, nameLength: UInt16(nameLen), kind: kind,
                multiLink: kind == .file && nlink > 1, size: kind == .file ? alloc : 0,
                mtime: mtime, dev: dev, ino: ino))
        }
    }
}
