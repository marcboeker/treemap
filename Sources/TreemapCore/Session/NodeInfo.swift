import Foundation

/// Snapshot of one node, for the inspector and the breadcrumb.
public struct NodeInfo: Sendable, Hashable {
    public var id: NodeID
    public var name: String
    /// Absolute path on disk.
    public var path: String
    /// Allocated bytes of the node and everything below it (lower bound while `.scanning`).
    public var size: Int64
    /// Number of files (non-directories) at or below the node; 1 for a file.
    public var itemCount: Int64
    /// Number of directories (mount points included) at or below the node, the node itself included.
    public var dirCount: Int64
    /// Number of unreadable directories at or below the node, the node itself included.
    public var unreadableCount: Int64
    public var modified: Date
    public var flags: CellFlags
    /// nil for the root.
    public var parent: NodeID?

    public var isDirectory: Bool { flags.contains(.directory) }
    public var url: URL { URL(fileURLWithPath: path) }
}

public enum SessionEvent: Sendable, Hashable {
    /// The tree changed; ask for a new layout. Coalesced to at most ~10 per second while scanning.
    case changed
    case progress(ScanProgress)
    /// The walk ended (completed or cancelled). The last `.changed` precedes it.
    case finished
}
