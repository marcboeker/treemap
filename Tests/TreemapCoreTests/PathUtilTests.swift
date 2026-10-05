import Testing
@testable import TreemapCore

@Suite struct PathUtilTests {
    @Test func join() {
        #expect(PathUtil.join("/", "a") == "/a")
        #expect(PathUtil.join("/a", "b") == "/a/b")
    }

    @Test func selfOrDescendant() {
        #expect(PathUtil.isSelfOrDescendant("/a", of: "/a"))
        #expect(PathUtil.isSelfOrDescendant("/a/b", of: "/a"))
        #expect(!PathUtil.isSelfOrDescendant("/ab", of: "/a"))
        #expect(!PathUtil.isSelfOrDescendant("/", of: "/a"))
        #expect(PathUtil.isSelfOrDescendant("/x", of: "/"))
        #expect(PathUtil.relative("/a/b/c", to: "/a") == "b/c")
        #expect(PathUtil.relative("/a", to: "/a") == "")
        #expect(PathUtil.relative("/x/y", to: "/") == "x/y")
        #expect(PathUtil.relative("/ab", to: "/a") == nil)
    }

    @Test func normalized() {
        #expect(PathUtil.normalized("/a/b//") == "/a/b")
        #expect(PathUtil.normalized("/") == "/")
        #expect(PathUtil.normalized("//") == "/")
    }

    @Test func skipRulesByParent() {
        let r = WalkRules(allowedDevices: [], skipPaths: ["/System/Volumes/Data", "/top/"])
        #expect(r.skipNames["/System/Volumes"] == [Array("Data".utf8)])
        #expect(r.skipNames["/"] == [Array("top".utf8)])
    }
}
