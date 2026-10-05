// Hit-testing over the pre-order cell array of a `TreemapLayout`. A child's rect lies inside
// its parent's, so only subtrees whose root contains the point can hold the hit: the descent
// skips every other subtree and costs O(depth × siblings) instead of O(cells).

import CoreGraphics

public struct CellHitIndex: Sendable {
    /// For each cell: index one past its last descendant.
    public let subtreeEnd: [Int32]

    public init(cells: [TreemapCell]) {
        var end = (0..<cells.count).map { Int32($0 + 1) }
        // Children follow their parent, so a backward pass sees every child before its parent.
        for i in stride(from: cells.count - 1, through: 1, by: -1) {
            let p = Int(cells[i].parent)
            if p >= 0, end[p] < end[i] { end[p] = end[i] }
        }
        subtreeEnd = end
    }

    /// Index of the deepest, topmost cell containing `point`, or nil. Same result as scanning
    /// `cells` backwards for the first rect that contains the point.
    public func cell(at point: CGPoint, in cells: [TreemapCell]) -> Int? {
        guard !cells.isEmpty, subtreeEnd.count == cells.count, cells[0].rect.contains(point) else { return nil }
        var hit = 0
        while true {
            // Later siblings draw on top: keep the last child that contains the point.
            var next = -1
            var j = hit + 1
            let end = Int(subtreeEnd[hit])
            while j < end {
                if cells[j].rect.contains(point) { next = j }
                j = Int(subtreeEnd[j])
            }
            if next < 0 { return hit }
            hit = next
        }
    }
}
