import AppKit
import TreemapCore

enum Fmt {
    static func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }

    /// Size with a "≥" prefix while the node is still being walked.
    static func size(_ info: NodeInfo) -> String {
        (info.flags.contains(.scanning) ? "≥ " : "") + bytes(info.size)
    }
}

/// Finder icons by path. `NSWorkspace.icon(forFile:)` hits the disk, and view bodies run often.
@MainActor
enum FileIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(forPath path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
