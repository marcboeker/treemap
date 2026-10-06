// Squarified treemap layout (Bruls, Huizing, van Wijk) over a `Tree`.
// Only visible cells are visited: a subtree whose rect is below `minCellArea` is never
// walked, and tiny siblings collapse into one `.aggregate` cell.

import CoreGraphics

public enum TreemapLayouter {
    /// Thresholds (points). Header: rect height >= 2 * headerHeight and width >= 3 * headerHeight.
    /// Label: width >= `labelMinWidth` and (header present or height >= `labelMinHeight`).
    public static let labelMinWidth: CGFloat = 30
    public static let labelMinHeight: CGFloat = 14

    static func layout(
        tree: Tree, root: NodeID, bounds: CGRect,
        options: LayoutOptions
    ) -> TreemapLayout {
        var engine = Engine(tree: tree, options: options)
        engine.cells.reserveCapacity(4096)
        engine.run(root: root, bounds: bounds)
        return TreemapLayout(root: root, bounds: bounds, cells: engine.cells)
    }

    /// One root directory with a file per entry of `sizes` (node 0 is the root, entry `n` is node `n + 1`).
    /// Public entry point for tools outside the module, e.g. make-icon.
    public static func layout(fileSizes sizes: [Int64], bounds: CGRect, options: LayoutOptions) -> TreemapLayout {
        var tree = Tree(rootName: "root", flags: .directory, scanning: false)
        var batch = Batch()
        for (i, s) in sizes.enumerated() {
            let name = Array("t\(i + 1)".utf8)
            batch.entries.append(.init(nameOffset: UInt32(batch.names.count), nameLength: UInt8(name.count), kind: .file,
                                       multiLink: false, size: s, mtime: 0, dev: 0, ino: 0))
            batch.names += name
        }
        _ = tree.publish(dir: 0, batch: batch, final: true)
        return layout(tree: tree, root: NodeID(raw: 0), bounds: bounds, options: options)
    }

    /// Golden-ratio hue on the stable NodeID: neighboring ids land far apart on the color wheel.
    static func hue(for id: NodeID) -> Float {
        let v = (0.08 + Double(id.raw) * 0.618034).truncatingRemainder(dividingBy: 1)
        return Float(v)
    }
}

private struct Item {
    var id: NodeID
    var size: Int64
    var weight: Double
    var flags: CellFlags
    var aggregateCount: Int32 // > 0: bucket of that many small items
}

private struct Engine {
    /// Stop recursing below this depth (relative to the view root).
    static let maxDepth = 12

    let tree: Tree
    let options: LayoutOptions
    var cells: [TreemapCell] = []

    init(tree: Tree, options: LayoutOptions) {
        self.tree = tree
        self.options = options
    }

    static var treeFlagMask: CellFlags { [.directory, .hidden, .scanning, .mountPoint, .unreadable] }

    mutating func run(root: NodeID, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let flags = tree.flags(of: root).intersection(Self.treeFlagMask)
        cells.append(TreemapCell(
            node: root, parent: -1, rect: bounds, depth: 0, hue: 0, flags: flags,
            name: tree.name(of: root), size: tree.size(of: root)))
        if flags.contains(.directory) {
            layoutDirectory(index: 0, id: root, depth: 0, hue: 0, isRoot: true)
        }
    }

    /// Lays out the children of the cell at `index`. The cell itself is already emitted.
    mutating func layoutDirectory(index: Int, id: NodeID, depth: Int, hue: Float, isRoot: Bool) {
        let rect = cells[index].rect
        let p = options.padding
        guard depth < Self.maxDepth,
              rect.width > 2 * p, rect.height > 2 * p,
              (rect.width - 2 * p) * (rect.height - 2 * p) >= options.minCellArea
        else { return }

        // Gather sizes and flags of the visible children.
        let tree = self.tree
        let drawHidden = options.drawHidden
        var items: [Item] = []
        var anyChild = false
        var knownSum = 0.0
        var knownCount = 0
        tree.forEachChild(of: id) { kid in
            anyChild = true
            let f = tree.flags(of: kid)
            if !drawHidden && f.contains(.hidden) { return }
            let s = tree.size(of: kid)
            if s <= 0 && !f.contains(.scanning) { return }
            if s > 0 { knownSum += Double(s); knownCount += 1 }
            items.append(Item(id: kid, size: max(s, 0), weight: Double(s), flags: f, aggregateCount: 0))
        }
        guard anyChild else { return }

        let hh = options.headerHeight
        let header = !isRoot && rect.height >= 2 * hh && rect.width >= 3 * hh
        var inner = CGRect(x: rect.minX + p, y: rect.minY + p,
                           width: rect.width - 2 * p, height: rect.height - 2 * p)
        if header {
            inner.origin.y += hh
            inner.size.height -= hh
            cells[index].flags.insert(.hasHeader)
            if rect.width >= TreemapLayouter.labelMinWidth { cells[index].flags.insert(.showsLabel) }
        }
        guard inner.width > 0, inner.height > 0, inner.width * inner.height >= options.minCellArea
        else { return }
        layoutChildren(consume items, knownSum: knownSum, knownCount: knownCount,
                       parentIndex: index, inner: inner, depth: depth + 1, hue: hue)
    }

    /// `items`: the visible children; `knownSum`/`knownCount` over those with a size > 0.
    mutating func layoutChildren(_ items: consuming [Item], knownSum: Double, knownCount: Int,
                                 parentIndex: Int, inner: CGRect, depth: Int, hue: Float) {
        guard !items.isEmpty else { return }

        // Stand-in weight for unread directories: mean of the known siblings.
        let standIn = knownCount > 0 ? knownSum / Double(knownCount) : 1
        var total = 0.0
        for i in items.indices {
            if items[i].size == 0 { items[i].weight = standIn }
            total += items[i].weight
        }

        // Padding is split between siblings: tessellate an area grown by p/2, shrink each cell.
        let half = options.padding / 2
        let area = inner.insetBy(dx: -half, dy: -half)
        let areaSize = area.width * area.height
        guard total > 0, areaSize > 0 else { return }
        let scale = areaSize / total

        // Pass 2: split off the tail below minCellArea (never sorted, never visited).
        let threshold = Double(options.minCellArea) / scale
        var big: [Item] = []
        big.reserveCapacity(items.count)
        var tailCount = 0
        var tailSize: Int64 = 0
        var tailWeight = 0.0
        var tailFirst: Item?
        for it in items {
            if it.weight >= threshold {
                big.append(it)
            } else {
                tailCount += 1
                tailSize += it.size
                tailWeight += it.weight
                if tailFirst == nil { tailFirst = it }
            }
        }
        let tree = self.tree
        big.sort { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            return tree.nameSortsBefore(a.id, b.id)
        }
        if tailCount == 1, let t = tailFirst {
            big.append(t)
        } else if tailCount > 1 {
            // The bucket's `id` is the parent's: only its hue reads it.
            big.append(Item(id: cells[parentIndex].node!, size: tailSize, weight: tailWeight,
                            flags: [], aggregateCount: Int32(tailCount)))
        }
        squarify(big, scale: scale, area: area, parentIndex: parentIndex, depth: depth, hue: hue)
    }

    mutating func squarify(_ items: [Item], scale: Double, area: CGRect,
                           parentIndex: Int, depth: Int, hue: Float) {
        let n = items.count
        var rx = Double(area.minX), ry = Double(area.minY)
        var rw = Double(area.width), rh = Double(area.height)
        var i = 0
        while i < n {
            if rw <= 0 || rh <= 0 { break }
            let short = min(rw, rh)
            let short2 = short * short
            var sum = 0.0
            var rmax = 0.0
            var rmin = Double.infinity
            var worst = Double.infinity
            var j = i
            while j < n {
                let a = items[j].weight * scale
                let s = sum + a
                let mx = max(rmax, a), mn = min(rmin, a)
                let w = max(short2 * mx / (s * s), (s * s) / (short2 * mn))
                if j > i && w > worst { break }
                sum = s; rmax = mx; rmin = mn; worst = w
                j += 1
            }
            if j == n { sum = max(sum, 0) }
            // Lay the row i..<j along the short side.
            if rw >= rh {
                let colW = j == n ? rw : min(sum / rh, rw)
                var y = ry
                for k in i..<j {
                    let a = items[k].weight * scale
                    let h = k == j - 1 ? (ry + rh - y) : (colW > 0 ? a / colW : 0)
                    place(items[k], tess: CGRect(x: rx, y: y, width: colW, height: h),
                          parentIndex: parentIndex, depth: depth, hue: hue)
                    y += h
                }
                rx += colW; rw -= colW
            } else {
                let rowH = j == n ? rh : min(sum / rw, rh)
                var x = rx
                for k in i..<j {
                    let a = items[k].weight * scale
                    let w = k == j - 1 ? (rx + rw - x) : (rowH > 0 ? a / rowH : 0)
                    place(items[k], tess: CGRect(x: x, y: ry, width: w, height: rowH),
                          parentIndex: parentIndex, depth: depth, hue: hue)
                    x += w
                }
                ry += rowH; rh -= rowH
            }
            i = j
        }
    }

    mutating func place(_ it: Item, tess: CGRect, parentIndex: Int, depth: Int, hue parentHue: Float) {
        let inset = min(options.padding / 2, min(tess.width, tess.height) / 4)
        let rect = tess.insetBy(dx: inset, dy: inset)
        let hue: Float = depth == 1 ? TreemapLayouter.hue(for: it.id) : parentHue
        let index = cells.count
        let w = rect.width, h = rect.height
        let roomy = w >= TreemapLayouter.labelMinWidth && h >= TreemapLayouter.labelMinHeight

        if it.aggregateCount > 0 {
            var f: CellFlags = [.aggregate]
            if roomy { f.insert(.showsLabel) }
            let name = it.aggregateCount == 1 ? "1 small item" : "\(it.aggregateCount) small items"
            cells.append(TreemapCell(node: nil, parent: Int32(parentIndex), rect: rect, depth: UInt8(clamping: depth),
                                     hue: hue, flags: f, name: name, size: it.size))
            return
        }
        var f = it.flags.intersection(Engine.treeFlagMask)
        cells.append(TreemapCell(node: it.id, parent: Int32(parentIndex), rect: rect, depth: UInt8(clamping: depth),
                                 hue: hue, flags: f, name: tree.name(of: it.id), size: it.size))
        if f.contains(.directory) && !f.contains(.mountPoint) {
            layoutDirectory(index: index, id: it.id, depth: depth, hue: hue, isRoot: false)
            f = cells[index].flags
        }
        if !f.contains(.hasHeader) && cells.count == index + 1 && roomy {
            cells[index].flags.insert(.showsLabel)
        }
    }
}
