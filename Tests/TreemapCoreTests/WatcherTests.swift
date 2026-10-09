import Darwin
import Foundation
import Testing
@testable import TreemapCore

@Suite struct WatcherTests {
    @Test func liveUpdateAddsAndRemovesFile() async throws {
        let f = try Fixture()
        try f.file("a/one", bytes: 10_000)
        try f.dir("b/deep")
        let s = await f.scan()
        let w = FileWatcher(session: s, debounce: .milliseconds(200), latency: 0.3)
        w.start()
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(500)) // let the stream settle

        let before = try #require(s.info(s.rootID)).size
        try f.file("b/deep/big", bytes: 1_048_576)
        #expect(await eventually { (s.info(s.rootID)?.size ?? 0) >= before + 1_000_000 })
        let big = try #require(s.node(atPath: f.path("b/deep/big")))
        #expect(s.info(big)!.size >= 1_048_576)

        try FileManager.default.removeItem(atPath: f.path("b/deep/big"))
        #expect(await eventually { (s.info(s.rootID)?.size ?? .max) <= before + 8192 })
        #expect(s.node(atPath: f.path("b/deep/big")) == nil)
    }

    @Test func eventsDuringScanAreHandledAfter() async throws {
        let f = try Fixture()
        try f.file("a/one", bytes: 4_096)
        let s = ScanSession(root: f.root, workerCount: 2)
        let w = FileWatcher(session: s, debounce: .milliseconds(100), latency: 0.2)
        w.start()
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(300))
        s.start()
        await s.waitUntilFinished()
        try f.file("a/two", bytes: 500_000)
        #expect(await eventually { s.node(atPath: f.path("a/two")) != nil })
    }

    @Test func nearestAncestorAndCollapse() async throws {
        let f = try Fixture()
        try f.file("a/b/c/x", bytes: 1)
        try f.dir("d")
        let s = await f.scan()
        let w = FileWatcher(session: s)
        let a = try #require(s.node(atPath: f.path("a")))
        let c = try #require(s.node(atPath: f.path("a/b/c")))
        let d = try #require(s.node(atPath: f.path("d")))
        #expect(w.nearestNode(for: f.path("a/b/c/new/deeper")) == c)
        #expect(w.nearestNode(for: f.path("a/b/c/")) == c)
        #expect(w.nearestNode(for: f.root.deletingLastPathComponent().path) == nil)
        #expect(w.nearestNode(for: "/elsewhere/x") == nil)
        #expect(Set(s.topLevel([a, c, d])) == [a, d])
        #expect(s.topLevel([c, a, c, d]).count == 2)
        #expect(s.deepestNodeAndFlags(atPath: f.path("a/b/c/new/deeper"))?.id == c)
        #expect(s.deepestNodeAndFlags(atPath: f.path("ab"))?.id == s.rootID)
    }

    @Test func rootGoneIsReported() async throws {
        let f = try Fixture()
        try f.file("a/one", bytes: 1)
        let s = await f.scan()
        let w = FileWatcher(session: s, debounce: .milliseconds(100), latency: 0.2)
        w.start()
        let gone = Task { () -> Bool in
            for await e in w.events where e == .rootGone { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(500))
        let moved = f.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: f.root, to: moved)
        let result = await withTaskGroup(of: Bool.self) { g in
            g.addTask { await gone.value }
            g.addTask { try? await Task.sleep(for: .seconds(8)); return false }
            let r = await g.next() ?? false
            g.cancelAll()
            return r
        }
        w.stop()
        try FileManager.default.moveItem(at: moved, to: f.root)
        #expect(result)
    }
}
