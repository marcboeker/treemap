// Shared contract between TreemapCore (tree + layout) and the App (renderer, UI).
// The App never touches the mutable tree. It asks a ScanSession for a TreemapLayout of
// the current view root and draws the flat cell array. Change these types only together
// with every user of them.

import CoreGraphics

/// Stable id of a node inside one scan session. Survives size updates and subtree rescans
/// (a rescanned node and its descendants keep their ids while their paths still exist);
/// a removed node's id is never reused within a session.
public struct NodeID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

/// Per-cell flags that change how a cell is drawn or how it reacts to input.
public struct CellFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory  = CellFlags(rawValue: 1 << 0)
    public static let hidden     = CellFlags(rawValue: 1 << 1) // name starts with "."
    public static let scanning   = CellFlags(rawValue: 1 << 2) // dir not fully walked yet; size is a lower bound
    public static let mountPoint = CellFlags(rawValue: 1 << 3) // other volume; not entered
    public static let unreadable = CellFlags(rawValue: 1 << 4) // permission denied / IO error
    public static let hasHeader  = CellFlags(rawValue: 1 << 5) // directory drawn with a label header strip
    public static let showsLabel = CellFlags(rawValue: 1 << 6) // enough room to draw the name
    /// "N small items" bucket, not a real node: the cell's `node` is nil.
    public static let aggregate  = CellFlags(rawValue: 1 << 7)
}

/// One drawable rectangle. Cells are ordered parents-before-children (pre-order), so a
/// renderer can draw in array order and a hit-test can scan in reverse order.
public struct TreemapCell: Sendable, Hashable {
    /// The node this cell draws; nil for an `.aggregate` cell, which stands for several small
    /// siblings and is not hoverable, selectable or trashable.
    public var node: NodeID?
    /// Index of the parent cell in `TreemapLayout.cells`, or -1 for the view root.
    public var parent: Int32
    /// Rectangle in view points, origin top-left (flipped, like AppKit flipped views).
    public var rect: CGRect
    /// Depth below the view root (root = 0).
    public var depth: UInt8
    /// Hue in 0..<1 of the depth-1 ancestor (the root has hue of its own index 0).
    public var hue: Float
    public var flags: CellFlags
    public var name: String
    /// Allocated bytes; a lower bound when `.scanning` is set.
    public var size: Int64

    public init(node: NodeID?, parent: Int32, rect: CGRect, depth: UInt8, hue: Float,
                flags: CellFlags, name: String, size: Int64) {
        self.node = node; self.parent = parent; self.rect = rect; self.depth = depth
        self.hue = hue; self.flags = flags; self.name = name; self.size = size
    }
}

public struct LayoutOptions: Sendable, Hashable {
    /// Gap between sibling cells and between a parent's edge and its children.
    public var padding: CGFloat = 3
    /// Height of a directory's label header strip.
    public var headerHeight: CGFloat = 18
    /// Cells smaller than this area (pt²) are not emitted; their parent shows them
    /// as one `.aggregate` cell instead.
    public var minCellArea: CGFloat = 12
    /// Hidden items still count in sizes, but are skipped in the drawing when false.
    public var drawHidden: Bool = true

    public init() {}
}

public struct TreemapLayout: Sendable {
    public var root: NodeID
    public var bounds: CGRect
    public var cells: [TreemapCell]

    public init(root: NodeID, bounds: CGRect, cells: [TreemapCell]) {
        self.root = root; self.bounds = bounds; self.cells = cells
    }
}

/// Live counters of a running or finished scan.
public struct ScanProgress: Sendable, Hashable {
    public var files: Int64 = 0
    public var directories: Int64 = 0
    public var errors: Int64 = 0
    public var bytes: Int64 = 0
    public var currentPath: String = ""
    public var finished: Bool = false
    public init() {}
}
