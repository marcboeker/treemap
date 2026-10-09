// Arena storage for the scanned tree. Struct-of-arrays indexed by `NodeID.raw`.
// Ids are append-only: a removed node stays in the arrays (marked dead) so its id is
// never reused inside one session. Not thread safe by itself: `TreeBox` guards it.
// ponytail: dead nodes are never freed (~70 B per file a live rescan replaces); a long-running window on a churning folder grows until it is closed. Compacting needs an id remap, which breaks stable NodeIDs.

import Synchronization

/// Identity of a hard-linked inode (same device + inode number).
struct LinkKey: Hashable, Sendable {
    var dev: Int32
    var ino: UInt64
}

struct Tree: Sendable {
    static let none = UInt32.max
    /// Owner marker for links whose first-seen node lives outside a rescan's side tree.
    static let outside = UInt32.max - 1
    /// Internal flag bit (outside the public `CellFlags` range): node was removed.
    static let deadBit: UInt16 = 1 << 15
    static let publicMask: UInt16 = 0x1F

    var parent = ContiguousArray<UInt32>()
    var firstChild = ContiguousArray<UInt32>()
    var nextSibling = ContiguousArray<UInt32>()
    var nameOffset = ContiguousArray<UInt32>()
    var nameLength = ContiguousArray<UInt16>()
    /// Allocated bytes of the node and everything below it.
    var size = ContiguousArray<Int64>()
    /// Files (non-directories) at or below the node; 1 for a file.
    var items = ContiguousArray<UInt32>()
    /// Directories (mount points included) at or below the node, the node itself included.
    var dirs = ContiguousArray<UInt32>()
    /// Unreadable directories at or below the node, the node itself included.
    var unreadable = ContiguousArray<UInt32>()
    var mtime = ContiguousArray<Int64>()
    var flags = ContiguousArray<UInt16>()
    /// Directories only, walk bookkeeping: unread token + child dirs not finished yet.
    var pending = ContiguousArray<UInt32>()
    /// All names, UTF-8, back to back.
    var names = ContiguousArray<UInt8>()
    /// First-seen owner of every inode with nlink > 1.
    var links: [LinkKey: UInt32] = [:]
    var generation: UInt64 = 0

    var count: Int { parent.count }

    /// Creates a tree whose node 0 is the root.
    init(rootName: String, flags rootFlags: CellFlags, size rootSize: Int64 = 0, mtime rootMTime: Int64 = 0,
         scanning: Bool, links: [LinkKey: UInt32] = [:]) {
        self.links = links
        var f = rootFlags.rawValue
        if rootName.utf8.first == 0x2E { f |= CellFlags.hidden.rawValue }
        let isDir = rootFlags.contains(.directory)
        if scanning && isDir { f |= CellFlags.scanning.rawValue }
        let bytes = Array(rootName.utf8)
        names.append(contentsOf: bytes)
        parent.append(Tree.none); firstChild.append(Tree.none); nextSibling.append(Tree.none)
        nameOffset.append(0); nameLength.append(UInt16(bytes.count))
        size.append(rootSize); items.append(isDir ? 0 : 1); mtime.append(rootMTime)
        dirs.append(isDir ? 1 : 0); unreadable.append(rootFlags.contains(.unreadable) ? 1 : 0)
        flags.append(f); pending.append(scanning && isDir ? 1 : 0)
    }

    // MARK: Queries

    func isAlive(_ i: UInt32) -> Bool {
        Int(i) < count && flags[Int(i)] & Tree.deadBit == 0
    }

    func nameString(_ i: UInt32) -> String {
        let o = Int(nameOffset[Int(i)])
        let l = Int(nameLength[Int(i)])
        return String(decoding: names[o..<o + l], as: UTF8.self)
    }

    func childIDs(_ i: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var c = firstChild[Int(i)]
        while c != Tree.none { out.append(c); c = nextSibling[Int(c)] }
        return out
    }

    func isDescendant(_ n: UInt32, of ancestor: UInt32) -> Bool {
        var cur = n
        while cur != Tree.none {
            if cur == ancestor { return true }
            cur = parent[Int(cur)]
        }
        return false
    }

    /// Absolute path of a node given the root's path.
    func path(of i: UInt32, rootPath: String) -> String {
        var parts: [String] = []
        var cur = i
        while parent[Int(cur)] != Tree.none {
            parts.append(nameString(cur))
            cur = parent[Int(cur)]
        }
        if parts.isEmpty { return rootPath }
        return PathUtil.join(rootPath, parts.reversed().joined(separator: "/"))
    }

    func child(of i: UInt32, named name: String) -> UInt32? {
        var c = firstChild[Int(i)]
        while c != Tree.none {
            if nameString(c) == name { return c }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    /// Like `child(of:named:)`, but compares raw UTF-8 bytes against the names pool (no allocation).
    func child(of i: UInt32, nameBytes: some Collection<UInt8>) -> UInt32? {
        let n = nameBytes.count
        var c = firstChild[Int(i)]
        while c != Tree.none {
            let l = Int(nameLength[Int(c)])
            if l == n {
                let o = Int(nameOffset[Int(c)])
                if names[o..<o + l].elementsEqual(nameBytes) { return c }
            }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    /// Nearest node at or above `i` that is still part of the tree.
    func nearestLive(_ i: UInt32) -> UInt32? {
        var cur = i
        while cur != Tree.none, Int(cur) < count {
            if isAlive(cur) { return cur }
            cur = parent[Int(cur)]
        }
        return nil
    }

    // MARK: Mutation

    /// Totals of one node that roll up into its ancestors.
    struct Tally {
        var size: Int64 = 0
        var items: Int64 = 0
        var dirs: Int64 = 0
        var unreadable: Int64 = 0

        static func - (a: Tally, b: Tally) -> Tally {
            Tally(size: a.size - b.size, items: a.items - b.items, dirs: a.dirs - b.dirs,
                  unreadable: a.unreadable - b.unreadable)
        }
        static prefix func - (a: Tally) -> Tally { Tally() - a }
    }

    func tally(_ id: UInt32) -> Tally {
        let i = Int(id)
        return Tally(size: size[i], items: Int64(items[i]), dirs: Int64(dirs[i]), unreadable: Int64(unreadable[i]))
    }

    private mutating func addUp(from start: UInt32, _ d: Tally) {
        var cur = start
        while cur != Tree.none {
            let i = Int(cur)
            size[i] += d.size
            items[i] = UInt32(truncatingIfNeeded: Int64(items[i]) + d.items)
            dirs[i] = UInt32(truncatingIfNeeded: Int64(dirs[i]) + d.dirs)
            unreadable[i] = UInt32(truncatingIfNeeded: Int64(unreadable[i]) + d.unreadable)
            cur = parent[i]
        }
    }

    /// Drops the "unread" token / finished-child count of `start` upwards and clears
    /// `.scanning` on every directory that is now complete.
    private mutating func finishChain(from start: UInt32) {
        var cur = start
        while cur != Tree.none, isAlive(cur) {
            let i = Int(cur)
            if pending[i] > 0 { pending[i] -= 1 }
            if pending[i] != 0 { return }
            flags[i] &= ~CellFlags.scanning.rawValue
            // The parent counted this directory as one unfinished child.
            cur = parent[i]
        }
    }

    struct PublishResult {
        var dirIDs: [UInt32] = []   // ids of the entries with kind == .walk, in batch order
        var files: Int64 = 0
        var dirs: Int64 = 0
        var bytes: Int64 = 0
    }

    /// Adds the entries of `batch` below `dir`. With `final`, the directory's own unread
    /// token is released. Returns nil when `dir` was removed in the meantime.
    mutating func publish(dir: UInt32, batch: Batch, final: Bool) -> PublishResult? {
        guard isAlive(dir) else { return nil }
        var result = PublishResult()
        let base = UInt32(names.count)
        names.append(contentsOf: batch.names)
        var addSize: Int64 = 0
        var addItems: Int64 = 0
        var walkCount: UInt32 = 0
        let d = Int(dir)
        for e in batch.entries {
            let id = UInt32(count)
            var f: UInt16 = 0
            var sz = e.size
            var it: UInt32 = 0
            var pend: UInt32 = 0
            switch e.kind {
            case .file:
                it = 1
                result.files += 1
                if e.multiLink {
                    let key = LinkKey(dev: e.dev, ino: e.ino)
                    if links[key] != nil { sz = 0 } else { links[key] = id }
                }
            case .walk:
                f = CellFlags.directory.rawValue | CellFlags.scanning.rawValue
                pend = 1
                walkCount += 1
                result.dirs += 1
                result.dirIDs.append(id)
            case .mount:
                f = CellFlags.directory.rawValue | CellFlags.mountPoint.rawValue
                result.dirs += 1
            }
            if batch.names[Int(e.nameOffset)] == 0x2E { f |= CellFlags.hidden.rawValue }
            parent.append(dir)
            firstChild.append(Tree.none)
            nextSibling.append(firstChild[d])
            firstChild[d] = id
            nameOffset.append(base + e.nameOffset)
            nameLength.append(e.nameLength)
            size.append(sz)
            items.append(it)
            dirs.append(e.kind == .file ? 0 : 1)
            unreadable.append(0)
            mtime.append(e.mtime)
            flags.append(f)
            pending.append(pend)
            addSize += sz
            addItems += Int64(it)
        }
        result.bytes = addSize
        pending[d] += walkCount
        addUp(from: dir, Tally(size: addSize, items: addItems, dirs: result.dirs))
        if final { finishChain(from: dir) }
        generation &+= 1
        return result
    }

    /// Marks a directory unreadable. With `final` also releases its unread token.
    mutating func markUnreadable(_ id: UInt32, final: Bool) {
        guard isAlive(id) else { return }
        if flags[Int(id)] & CellFlags.unreadable.rawValue == 0 {
            flags[Int(id)] |= CellFlags.unreadable.rawValue
            addUp(from: id, Tally(unreadable: 1))
        }
        if final { finishChain(from: id) }
        generation &+= 1
    }

    private mutating func killSubtree(_ id: UInt32, includingRoot: Bool) {
        var stack: [UInt32] = includingRoot ? [id] : childIDs(id)
        while let n = stack.popLast() {
            flags[Int(n)] |= Tree.deadBit
            var c = firstChild[Int(n)]
            while c != Tree.none { stack.append(c); c = nextSibling[Int(c)] }
        }
    }

    /// Detaches `id` (and everything below) and subtracts its size from the ancestors.
    @discardableResult
    mutating func remove(_ id: UInt32) -> Bool {
        guard isAlive(id), parent[Int(id)] != Tree.none else { return false }
        let p = parent[Int(id)]
        let wasScanning = flags[Int(id)] & CellFlags.scanning.rawValue != 0
        // Unlink from the sibling list.
        if firstChild[Int(p)] == id {
            firstChild[Int(p)] = nextSibling[Int(id)]
        } else {
            var c = firstChild[Int(p)]
            while c != Tree.none {
                if nextSibling[Int(c)] == id { nextSibling[Int(c)] = nextSibling[Int(id)]; break }
                c = nextSibling[Int(c)]
            }
        }
        addUp(from: p, -tally(id))
        killSubtree(id, includingRoot: true)
        if wasScanning { finishChain(from: p) }
        generation &+= 1
        return true
    }

    /// Replaces everything below `t` with the subtree of `side` (a fully walked tree) at
    /// `sideRoot`, which stands for `t`. Nodes are matched by name under the same parent: a
    /// node that is still there keeps its id, a vanished one is removed, a new one gets a
    /// fresh id. Ancestors get the size delta.
    mutating func graft(_ side: Tree, from sideRoot: UInt32 = 0, onto t: UInt32) {
        guard isAlive(t) else { return }
        let ti = Int(t)
        let old = tally(t)
        let sr = Int(sideRoot)
        let wasScanning = flags[ti] & CellFlags.scanning.rawValue != 0

        // Pass 1 (read only): side index -> id in this tree. Reused ids keep their name,
        // parent and place; `fresh` lists the side nodes that need a new id, in id order.
        var idMap = [UInt32](repeating: Tree.none, count: side.count)
        idMap[sr] = t
        var fresh: [UInt32] = []
        var dropped: [UInt32] = []
        var stack: [(side: UInt32, old: UInt32?)] = [(sideRoot, t)]
        while let (s, old) = stack.popLast() {
            var unmatched: [String: UInt32] = [:]
            if let old {
                var c = firstChild[Int(old)]
                while c != Tree.none { unmatched[nameString(c)] = c; c = nextSibling[Int(c)] }
            }
            var sc = side.firstChild[Int(s)]
            while sc != Tree.none {
                if let oc = unmatched.removeValue(forKey: side.nameString(sc)) {
                    idMap[Int(sc)] = oc
                    stack.append((sc, oc))
                } else {
                    idMap[Int(sc)] = UInt32(count + fresh.count)
                    fresh.append(sc)
                    stack.append((sc, nil))
                }
                sc = side.nextSibling[Int(sc)]
            }
            dropped.append(contentsOf: unmatched.values)
        }
        func map(_ x: UInt32) -> UInt32 { x == Tree.none ? Tree.none : idMap[Int(x)] }

        // Links first seen inside `t` are re-established from the side tree.
        links = links.filter { _, owner in owner == t || !isDescendant(owner, of: t) }
        for d in dropped { killSubtree(d, includingRoot: true) }

        // Pass 2: append the new nodes, then copy every side node's data and child list.
        for s in fresh {
            let si = Int(s)
            let o = Int(side.nameOffset[si]), l = Int(side.nameLength[si])
            parent.append(map(side.parent[si]))
            firstChild.append(Tree.none)
            nextSibling.append(Tree.none)
            nameOffset.append(UInt32(names.count))
            nameLength.append(side.nameLength[si])
            names.append(contentsOf: side.names[o..<o + l])
            size.append(0); items.append(0); dirs.append(0); unreadable.append(0)
            mtime.append(0); flags.append(0); pending.append(0)
        }
        for si in 0..<side.count {
            let id = idMap[si]
            guard id != Tree.none else { continue }
            let i = Int(id)
            firstChild[i] = map(side.firstChild[si])
            size[i] = side.size[si]
            items[i] = side.items[si]
            dirs[i] = side.dirs[si]
            unreadable[i] = side.unreadable[si]
            mtime[i] = side.mtime[si]
            if si == sr { continue }   // `t` keeps its siblings; its flags are set below
            nextSibling[i] = map(side.nextSibling[si])
            flags[i] = side.flags[si]
            pending[i] = side.pending[si]
        }
        flags[ti] = side.flags[sr] & ~CellFlags.scanning.rawValue
        pending[ti] = 0
        for (k, owner) in side.links where owner != Tree.outside && idMap[Int(owner)] != Tree.none {
            links[k] = idMap[Int(owner)]
        }
        let p = parent[ti]
        addUp(from: p, side.tally(sideRoot) - old)
        if wasScanning { finishChain(from: p) }
        generation &+= 1
    }

    /// Link table to seed a rescan of the subtrees `targets`: inodes first seen outside all
    /// of them stay owned (so they count 0 again), inodes first seen inside one are forgotten.
    func linksForRescan(of targets: [UInt32]) -> [LinkKey: UInt32] {
        var out: [LinkKey: UInt32] = [:]
        for (k, owner) in links where isAlive(owner) && !targets.contains(where: { isDescendant(owner, of: $0) }) {
            out[k] = Tree.outside
        }
        return out
    }
}

/// Lock-guarded tree shared between the session and the walker threads.
final class TreeBox: Sendable {
    let state: Mutex<Tree>
    init(_ tree: consuming Tree) { state = Mutex(tree) }
}

// MARK: Layout queries

extension Tree {
    func name(of id: NodeID) -> String { nameString(id.raw) }
    func size(of id: NodeID) -> Int64 { size[Int(id.raw)] }
    func flags(of id: NodeID) -> CellFlags { CellFlags(rawValue: flags[Int(id.raw)] & Tree.publicMask) }
    func forEachChild(of id: NodeID, _ body: (NodeID) -> Void) {
        var c = firstChild[Int(id.raw)]
        while c != Tree.none { body(NodeID(raw: c)); c = nextSibling[Int(c)] }
    }
    /// Tie-breaker for equal sizes: true when `a`'s name sorts before `b`'s.
    func nameSortsBefore(_ a: NodeID, _ b: NodeID) -> Bool {
        let oa = Int(nameOffset[Int(a.raw)]), ob = Int(nameOffset[Int(b.raw)])
        return names[oa..<oa + Int(nameLength[Int(a.raw)])]
            .lexicographicallyPrecedes(names[ob..<ob + Int(nameLength[Int(b.raw)])])
    }
}

// MARK: Walk batches

/// Directory entries parsed by a worker, published in one lock acquisition.
struct Batch: Sendable {
    enum Kind: UInt8, Sendable { case file, walk, mount }
    struct Entry: Sendable {
        var nameOffset: UInt32
        var nameLength: UInt16
        var kind: Kind
        var multiLink: Bool
        var size: Int64
        var mtime: Int64
        var dev: Int32
        var ino: UInt64
    }
    var names: [UInt8] = []
    var entries: [Entry] = []
}
