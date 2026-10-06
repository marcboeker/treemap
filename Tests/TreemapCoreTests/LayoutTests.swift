import CoreGraphics
import Foundation
import Testing
@testable import TreemapCore

final class LayoutFixture {
    var tree = Tree(rootName: "root", flags: .directory, scanning: false)
    private var started = false

    @discardableResult
    func add(_ name: String, size: Int64 = 0, flags: CellFlags = [], parent: NodeID? = nil) -> NodeID {
        let id = UInt32(started ? tree.count : 0)
        guard started else { started = true; return NodeID(raw: 0) } // first call is the root, already in `tree`
        let bytes = Array(name.utf8)
        let p = parent!.raw
        tree.parent.append(p)
        tree.firstChild.append(Tree.none)
        tree.nextSibling.append(tree.firstChild[Int(p)])
        tree.firstChild[Int(p)] = id
        tree.nameOffset.append(UInt32(tree.names.count)); tree.nameLength.append(UInt8(bytes.count))
        tree.names.append(contentsOf: bytes)
        tree.size.append(size); tree.items.append(0); tree.dirs.append(0); tree.unreadable.append(0)
        tree.mtime.append(0); tree.flags.append(flags.rawValue); tree.pending.append(0)
        return NodeID(raw: id)
    }
    func dir(_ name: String, flags: CellFlags = [], parent: NodeID? = nil) -> NodeID {
        add(name, flags: flags.union(.directory), parent: parent)
    }
    /// Sum file sizes up into directories (unless a directory already has a size set).
    func finalize() {
        var acc = [Int64](repeating: 0, count: tree.count)
        for i in stride(from: tree.count - 1, through: 0, by: -1) {
            if tree.firstChild[i] != Tree.none { tree.size[i] = acc[i] }
            if tree.parent[i] != Tree.none { acc[Int(tree.parent[i])] += tree.size[i] }
        }
    }
}

private let view = CGRect(x: 0, y: 0, width: 800, height: 600)

private func run(_ t: LayoutFixture, root: NodeID = NodeID(raw: 0), bounds: CGRect = view,
                 _ tweak: (inout LayoutOptions) -> Void = { _ in }) -> TreemapLayout {
    var o = LayoutOptions()
    tweak(&o)
    return TreemapLayouter.layout(tree: t.tree, root: root, bounds: bounds, options: o)
}

private func sample() -> LayoutFixture {
    let t = LayoutFixture()
    let r = t.dir("root")
    let a = t.dir("a", parent: r)
    let b = t.dir("b", parent: r)
    t.add("c.bin", size: 1000, parent: r)
    for i in 0..<6 { t.add("a\(i)", size: Int64(500 + i * 100), parent: a) }
    for i in 0..<4 { t.add("b\(i)", size: Int64(300 + i * 50), parent: b) }
    t.add(".hidden", size: 900, flags: .hidden, parent: r)
    t.finalize()
    return t
}

@Suite("Layout") struct LayoutTests {
    @Test func rootCellAndMetadata() {
        let l = run(sample())
        #expect(l.cells[0].parent == -1)
        #expect(l.cells[0].depth == 0)
        #expect(l.cells[0].hue == 0)
        #expect(l.cells[0].rect == view)
        #expect(!l.cells[0].flags.contains(.hasHeader))
    }

    @Test func preOrderAndDepth() {
        let l = run(sample())
        for (i, c) in l.cells.enumerated() where i > 0 {
            #expect(Int(c.parent) < i)
            #expect(c.depth == l.cells[Int(c.parent)].depth + 1)
        }
        // A parent's descendants are contiguous: no cell between parent and its last child
        // may belong to a different subtree.
        var stack: [Int] = [0]
        for (i, c) in l.cells.enumerated() where i > 0 {
            while let top = stack.last, top != Int(c.parent) { stack.removeLast() }
            #expect(stack.last == Int(c.parent))
            stack.append(i)
        }
    }

    @Test func areasProportionalAndNoOverlap() {
        let t = sample()
        let l = run(t) { $0.padding = 1; $0.minCellArea = 0 }
        let rootKids = l.cells.indices.filter { l.cells[$0].parent == 0 && !l.cells[$0].flags.contains(.aggregate) }
        for i in rootKids {
            for j in rootKids where j > i {
                #expect(!l.cells[i].rect.insetBy(dx: 0.01, dy: 0.01).intersects(l.cells[j].rect.insetBy(dx: 0.01, dy: 0.01)))
            }
        }
        let a = l.cells[rootKids[0]], total = rootKids.reduce(0.0) { $0 + Double(l.cells[$1].rect.width * l.cells[$1].rect.height) }
        let ratio = Double(a.rect.width * a.rect.height) / total
        let expected = Double(a.size) / Double(rootKids.reduce(0) { $0 + l.cells[$1].size })
        #expect(abs(ratio - expected) < 0.05)
    }

    @Test func childrenInsideParentInner() {
        let l = run(sample())
        for c in l.cells where c.parent >= 0 {
            let p = l.cells[Int(c.parent)]
            var inner = p.rect.insetBy(dx: 0, dy: 0)
            if p.flags.contains(.hasHeader) { inner.origin.y += 16; inner.size.height -= 16 }
            #expect(c.rect.minX >= inner.minX - 0.001 && c.rect.maxX <= inner.maxX + 0.001)
            #expect(c.rect.minY >= inner.minY - 0.001 && c.rect.maxY <= inner.maxY + 0.001)
        }
    }

    @Test func headersAndLabels() {
        let l = run(sample())
        let dirs = l.cells.filter { $0.flags.contains(.directory) && $0.depth == 1 }
        #expect(!dirs.isEmpty)
        for d in dirs { #expect(d.flags.contains(.hasHeader) && d.flags.contains(.showsLabel)) }
        let tiny = run(sample(), bounds: CGRect(x: 0, y: 0, width: 60, height: 30))
        #expect(tiny.cells.allSatisfy { !$0.flags.contains(.hasHeader) })
    }

    @Test func aggregateBucket() {
        let t = LayoutFixture()
        let r = t.dir("root")
        t.add("big", size: 1_000_000, parent: r)
        for i in 0..<50 { t.add("s\(i)", size: 10, parent: r) }
        t.finalize()
        let l = run(t, bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let aggs = l.cells.filter { $0.flags.contains(.aggregate) }
        #expect(aggs.count == 1)
        #expect(aggs[0].name == "50 small items")
        #expect(aggs[0].node == nil)
        #expect(l.cells[Int(aggs[0].parent)].node == r)
        #expect(aggs[0].size == 500)
        #expect(l.cells.last?.flags.contains(.aggregate) == true)
    }

    @Test func hiddenToggle() {
        let t = sample()
        let shown = run(t)
        let hidden = run(t) { $0.drawHidden = false }
        #expect(shown.cells.contains { $0.name == ".hidden" })
        #expect(!hidden.cells.contains { $0.name == ".hidden" })
        #expect(hidden.cells[0].size == shown.cells[0].size)
        let c = hidden.cells.first { $0.name == "c.bin" }!
        let c0 = shown.cells.first { $0.name == "c.bin" }!
        #expect(c.rect.width * c.rect.height > c0.rect.width * c0.rect.height)
        #expect(shown.cells.first { $0.name == ".hidden" }!.flags.contains(.hidden))
    }

    @Test func hueInheritance() {
        let l = run(sample())
        var hues = Set<Float>()
        for (i, c) in l.cells.enumerated() where c.depth >= 1 {
            var k = i
            while l.cells[k].depth > 1 { k = Int(l.cells[k].parent) }
            #expect(c.hue == l.cells[k].hue)
            if c.depth == 1 { hues.insert(c.hue) }
            #expect(c.hue >= 0 && c.hue < 1)
        }
        #expect(hues.count == l.cells.filter { $0.depth == 1 }.count)
    }

    @Test func hueStableAcrossSizeReorder() {
        let t = sample()
        let before = run(t)
        let a = NodeID(raw: t.tree.childIDs(0)[0]), b = NodeID(raw: t.tree.childIDs(0)[1])
        t.tree.size[Int(a.raw)] = 1; t.tree.size[Int(b.raw)] = 5_000_000
        let after = run(t)
        for n in [a, b] {
            let h0 = before.cells.first { $0.node == n }!.hue
            let h1 = after.cells.first { $0.node == n }!.hue
            #expect(h0 == h1)
            #expect(h0 == TreemapLayouter.hue(for: n))
        }
    }

    @Test func deterministic() {
        let t = sample()
        let a = run(t), b = run(t)
        #expect(a.cells == b.cells)
    }

    @Test func scanningStandIn() {
        let t = LayoutFixture()
        let r = t.dir("root")
        t.add("f1", size: 400, parent: r)
        t.add("f2", size: 600, parent: r)
        let s = t.dir("pending", flags: .scanning, parent: r)
        t.finalize()
        t.tree.size[Int(s.raw)] = 0
        t.tree.size[0] = 1000
        let l = run(t)
        let c = l.cells.first { $0.node == s }
        #expect(c != nil)
        #expect(c!.size == 0)
        #expect(c!.flags.contains(.scanning))
        let f1 = l.cells.first { $0.name == "f1" }!
        // stand-in weight 500 -> roughly between f1 (400) and f2 (600) in area
        let area = { (x: TreemapCell) in x.rect.width * x.rect.height }
        #expect(area(c!) > area(f1) * 0.8)
    }

    @Test func zeroSizeSkipped() {
        let t = LayoutFixture()
        let r = t.dir("root")
        t.add("z", size: 0, parent: r)
        t.add("f", size: 10, parent: r)
        t.finalize()
        #expect(!run(t).cells.contains { $0.name == "z" })
    }

    @Test func hitIndexMatchesLinearScan() {
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        let t = LayoutFixture()
        _ = t.dir("root")
        var i = 0
        while t.tree.count < 20_000 && i < t.tree.count {
            if CellFlags(rawValue: t.tree.flags[i]).contains(.directory) {
                for k in 0..<(2 + Int(next() % 20)) {
                    let isDir = next() % 4 == 0
                    t.add("n\(k)", size: isDir ? 0 : Int64(next() % 100_000 + 1),
                          flags: isDir ? .directory : [], parent: NodeID(raw: UInt32(i)))
                }
            }
            i += 1
        }
        t.finalize()
        let l = run(t, bounds: CGRect(x: 0, y: 0, width: 1400, height: 900))
        let index = CellHitIndex(cells: l.cells)
        func linear(_ p: CGPoint) -> Int? { l.cells.indices.last { l.cells[$0].rect.contains(p) } }
        var points: [CGPoint] = (0..<4000).map { _ in
            CGPoint(x: Double(next() % 1_420_000) / 1000 - 10, y: Double(next() % 920_000) / 1000 - 10)
        }
        // Edges are where an off-by-one would show.
        for c in l.cells.prefix(500) {
            points += [c.rect.origin, CGPoint(x: c.rect.maxX, y: c.rect.maxY),
                       CGPoint(x: c.rect.maxX - 0.001, y: c.rect.midY)]
        }
        #expect(l.cells.count > 1000)
        for p in points {
            #expect(index.cell(at: p, in: l.cells) == linear(p))
        }
    }

    @Test func performanceMillionNodes() {
        // BFS-built tree: children of a node are contiguous.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        let t = LayoutFixture()
        let total = 1_000_000
        _ = t.dir("root")
        var i = 0
        while t.tree.count < total && i < t.tree.count {
            if CellFlags(rawValue: t.tree.flags[i]).contains(.directory) {
                let n = 2 + Int(next() % 30)
                for k in 0..<n where t.tree.count < total {
                    let isDir = next() % 4 == 0
                    let id = t.add("n\(k)", size: isDir ? 0 : Int64(next() % 1_000_000 + 1),
                                   flags: isDir ? .directory : [], parent: NodeID(raw: UInt32(i)))
                    _ = id
                }
            }
            i += 1
        }
        t.finalize()
        let bounds = CGRect(x: 0, y: 0, width: 2560, height: 1600)
        var best = Double.infinity
        var count = 0
        for _ in 0..<5 {
            var l: TreemapLayout?
            let elapsed = ContinuousClock().measure {
                l = TreemapLayouter.layout(tree: t.tree, root: NodeID(raw: 0), bounds: bounds, options: LayoutOptions())
            }
            best = min(best, elapsed / .milliseconds(1)); count = l?.cells.count ?? 0
        }
        print("LAYOUT 1M nodes: \(count) cells, best \(String(format: "%.2f", best)) ms")
        #if !DEBUG
        #expect(best < 16)
        #endif
        #expect(count > 100)
    }
}
