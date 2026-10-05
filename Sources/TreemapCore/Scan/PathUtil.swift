// String path helpers for the hot paths (walk, queue, lookups). Byte-wise on UTF-8, no URL,
// no Foundation path APIs. Paths are absolute and "/"-separated.

enum PathUtil {
    private static let slash = UInt8(ascii: "/")

    /// `parent/name`, without a double slash when `parent` is "/".
    static func join(_ parent: String, _ name: String) -> String {
        if parent == "/" { return "/" + name }
        var s = parent
        s.reserveCapacity(parent.utf8.count + 1 + name.utf8.count)
        s += "/"
        s += name
        return s
    }

    /// True when `path` is `root` or lies below it. "/ab" is not below "/a".
    static func isSelfOrDescendant(_ path: String, of root: String) -> Bool {
        let p = path.utf8, r = root.utf8
        guard p.starts(with: r) else { return false }
        if p.count == r.count || r.last == slash { return true }
        return p[p.index(p.startIndex, offsetBy: r.count)] == slash
    }

    /// The part of `path` below `root` ("" for the root itself); nil when `path` is outside.
    static func relative(_ path: String, to root: String) -> Substring? {
        guard isSelfOrDescendant(path, of: root) else { return nil }
        let u = path.utf8
        var i = u.index(u.startIndex, offsetBy: root.utf8.count)
        if i < u.endIndex && u[i] == slash { i = u.index(after: i) }
        return path[i...]
    }

    /// Drops trailing slashes; "/" (and "//...") stays "/".
    static func normalized(_ path: String) -> String {
        var s = path
        while s.utf8.count > 1 && s.utf8.last == slash { s.removeLast() }
        return s
    }
}
