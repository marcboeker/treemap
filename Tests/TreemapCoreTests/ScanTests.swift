import Darwin
import Foundation
import Testing
@testable import TreemapCore

/// Temp-dir fixture, removed on deinit.
final class Fixture {
    let root: URL
    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("treemap-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit {
        // Restore permissions so removal works.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let p as String in e { chmod(root.appendingPathComponent(p).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }
    func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }
    func dir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
    }
    @discardableResult
    func file(_ rel: String, bytes: Int) throws -> String {
        try dir((rel as NSString).deletingLastPathComponent)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path(rel)))
        return path(rel)
    }
    func scan(workers: Int = 4) async -> ScanSession {
        let s = ScanSession(root: root, workerCount: workers)
        s.start()
        await s.waitUntilFinished()
        return s
    }
}

/// Polls until `cond` holds or `seconds` passed.
func eventually(_ seconds: Double = 8, every interval: Duration = .milliseconds(100),
                _ cond: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end {
        if cond() { return true }
        try? await Task.sleep(for: interval)
    }
    return cond()
}

func duBytes(_ path: String) throws -> Int64 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-sk", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return Int64(out.split(whereSeparator: \.isWhitespace).first ?? "0")! * 1024
}

@Suite struct ScanTests {
    @Test func sizesSumAndMatchDu() async throws {
        let f = try Fixture()
        try f.file("a/one", bytes: 10_000)
        try f.file("a/b/two", bytes: 100_000)
        try f.file("a/b/c/three", bytes: 1)
        try f.file("top", bytes: 5_000)
        try f.dir("empty")
        let s = await f.scan()
        let root = try #require(s.info(s.rootID))
        let a = try #require(s.node(atPath: f.path("a")))
        let b = try #require(s.node(atPath: f.path("a/b")))
        let kids = s.children(of: s.rootID).compactMap { s.info($0) }.reduce(0) { $0 + $1.size }
        #expect(root.size == kids)
        #expect(root.size == s.info(a)!.size + s.info(s.node(atPath: f.path("top"))!)!.size)
        #expect(s.info(a)!.size >= s.info(b)!.size + 12288)
        #expect(root.itemCount == 4)
        #expect(!root.flags.contains(.scanning))
        #expect(s.progress.finished)
        #expect(s.progress.files == 4)
        #expect(s.progress.directories == 5)
        #expect(root.dirCount == 5)
        #expect(root.unreadableCount == 0)
        #expect(root.size == (try duBytes(f.root.path)))
    }

    @Test func hardLinksCountOnce() async throws {
        let f = try Fixture()
        let orig = try f.file("d1/orig", bytes: 50_000)
        try f.dir("d2")
        #expect(link(orig, f.path("d2/link1")) == 0)
        #expect(link(orig, f.path("d1/link2")) == 0)
        let s = await f.scan()
        let sizes = ["d1/orig", "d1/link2", "d2/link1"].map { s.info(s.node(atPath: f.path($0))!)!.size }
        let single = sizes.max()!
        #expect(single >= 50_000)  // first seen wins; which link is first is not defined
        #expect(s.info(s.rootID)!.size == single)
        #expect(s.info(s.rootID)!.itemCount == 3)
        #expect(sizes.filter { $0 == 0 }.count == 2)
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
    }

    @Test func symlinksAreLeaves() async throws {
        let f = try Fixture()
        try f.file("real/big", bytes: 200_000)
        try f.dir("other")
        #expect(symlink(f.path("real"), f.path("other/dirlink")) == 0)
        #expect(symlink(f.path("real/big"), f.path("other/filelink")) == 0)
        let s = await f.scan()
        let dl = try #require(s.node(atPath: f.path("other/dirlink")))
        #expect(!s.info(dl)!.isDirectory)
        #expect(s.children(of: dl).isEmpty)
        #expect(s.info(s.node(atPath: f.path("other"))!)!.size < 8192)
        #expect(s.info(s.rootID)!.itemCount == 3)
    }

    @Test func hiddenFlag() async throws {
        let f = try Fixture()
        try f.file(".secret", bytes: 10)
        try f.file(".hiddendir/x", bytes: 10)
        try f.file("plain", bytes: 10)
        let s = await f.scan()
        #expect(s.info(s.node(atPath: f.path(".secret"))!)!.flags.contains(.hidden))
        #expect(s.info(s.node(atPath: f.path(".hiddendir"))!)!.flags.contains(.hidden))
        #expect(!s.info(s.node(atPath: f.path(".hiddendir/x"))!)!.flags.contains(.hidden))
        #expect(!s.info(s.node(atPath: f.path("plain"))!)!.flags.contains(.hidden))
    }

    @Test func unreadableDirectory() async throws {
        let f = try Fixture()
        try f.file("ok/x", bytes: 1000)
        try f.file("locked/y", bytes: 1000)
        chmod(f.path("locked"), 0)
        let s = await f.scan()
        let locked = try #require(s.node(atPath: f.path("locked")))
        #expect(s.info(locked)!.flags.contains(.unreadable))
        #expect(!s.info(locked)!.flags.contains(.scanning))
        #expect(s.progress.errors == 1)
        #expect(!s.info(s.rootID)!.flags.contains(.scanning))
        #expect(s.info(s.rootID)!.unreadableCount == 1)
        #expect(s.info(locked)!.unreadableCount == 1)
        #expect(s.info(s.rootID)!.dirCount == 3)
        // Removing the unreadable dir drops it from the totals.
        s.remove([locked])
        #expect(s.info(s.rootID)!.unreadableCount == 0)
        #expect(s.info(s.rootID)!.dirCount == 2)
    }

    @Test func removeSubtractsFromAncestors() async throws {
        let f = try Fixture()
        try f.file("a/b/big", bytes: 300_000)
        try f.file("a/small", bytes: 1000)
        try f.file("keep", bytes: 5000)
        let s = await f.scan()
        let before = s.info(s.rootID)!
        let b = try #require(s.node(atPath: f.path("a/b")))
        let bSize = s.info(b)!.size
        let aBefore = s.info(s.node(atPath: f.path("a"))!)!.size
        let removed = s.remove([b, b])
        #expect(removed == [b])
        #expect(s.info(b) == nil)
        #expect(!s.isAlive(b))
        #expect(s.nearestLiveAncestor(of: b) == s.node(atPath: f.path("a")))
        #expect(s.nearestLiveAncestor(of: s.rootID) == s.rootID)
        #expect(s.path(of: b) == nil)
        #expect(s.node(atPath: f.path("a/b")) == nil)
        #expect(s.info(s.rootID)!.size == before.size - bSize)
        #expect(s.info(s.node(atPath: f.path("a"))!)!.size == aBefore - bSize)
        #expect(s.info(s.rootID)!.itemCount == before.itemCount - 1)
        #expect(s.remove([s.rootID]).isEmpty)
        // Ids are not reused.
        try f.file("a/new", bytes: 10)
        await s.rescan([s.node(atPath: f.path("a"))!])
        let newID = try #require(s.node(atPath: f.path("a/new")))
        #expect(newID.raw > b.raw)
    }

    @Test func rescanAppliesDelta() async throws {
        let f = try Fixture()
        try f.file("a/old", bytes: 100_000)
        try f.file("a/sub/deep", bytes: 100_000)
        try f.file("z", bytes: 8000)
        let s = await f.scan()
        let a = try #require(s.node(atPath: f.path("a")))
        let before = s.info(s.rootID)!.size
        try FileManager.default.removeItem(atPath: f.path("a/old"))
        try f.file("a/added1", bytes: 400_000)
        try f.file("a/added2", bytes: 20_000)
        await s.rescan([a])
        #expect(s.node(atPath: f.path("a")) == a)
        #expect(s.node(atPath: f.path("a/old")) == nil)
        #expect(s.node(atPath: f.path("a/sub/deep")) != nil)
        let after = s.info(s.rootID)!
        #expect(after.size != before)
        #expect(after.size == (try duBytes(f.root.path)))
        #expect(after.itemCount == 4)
        #expect(!s.info(a)!.flags.contains(.scanning))
        // Vanished path removes the node.
        try FileManager.default.removeItem(atPath: f.path("a"))
        await s.rescan([a])
        #expect(s.info(a) == nil)
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
    }

    @Test func rescanKeepsIDsOfUnchangedNodes() async throws {
        let f = try Fixture()
        try f.file("a/keep", bytes: 10_000)
        try f.file("a/gone", bytes: 10_000)
        try f.file("a/sub/deep", bytes: 20_000)
        try f.file("a/sub/gone2/x", bytes: 1000)
        try f.file("b/other", bytes: 5000)
        let s = await f.scan()
        let a = try #require(s.node(atPath: f.path("a")))
        let keep = try #require(s.node(atPath: f.path("a/keep")))
        let sub = try #require(s.node(atPath: f.path("a/sub")))
        let deep = try #require(s.node(atPath: f.path("a/sub/deep")))
        let gone = try #require(s.node(atPath: f.path("a/gone")))
        let gone2x = try #require(s.node(atPath: f.path("a/sub/gone2/x")))
        let other = try #require(s.node(atPath: f.path("b/other")))
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hues = Dictionary(s.layout(viewRoot: s.rootID, bounds: bounds).cells.compactMap { c in c.node.map { ($0, c.hue) } },
                              uniquingKeysWith: { a, _ in a })

        try FileManager.default.removeItem(atPath: f.path("a/gone"))
        try FileManager.default.removeItem(atPath: f.path("a/sub/gone2"))
        try f.file("a/sub/new", bytes: 30_000)
        await s.rescan([a])

        #expect(s.node(atPath: f.path("a")) == a)
        #expect(s.node(atPath: f.path("a/keep")) == keep)
        #expect(s.node(atPath: f.path("a/sub")) == sub)
        #expect(s.node(atPath: f.path("a/sub/deep")) == deep)
        #expect(s.node(atPath: f.path("b/other")) == other)
        #expect(!s.isAlive(gone) && !s.isAlive(gone2x))
        let new = try #require(s.node(atPath: f.path("a/sub/new")))
        #expect(new.raw > gone2x.raw)
        #expect(s.info(sub)!.size >= 50_000)
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
        #expect(s.info(s.rootID)!.itemCount == 4)
        #expect(Set(s.children(of: sub)) == [deep, new])
        // root, a, a/sub, b (a/sub/gone2 is gone).
        #expect(s.info(s.rootID)!.dirCount == 4)
        #expect(s.info(a)!.dirCount == 2)
        let after = s.layout(viewRoot: s.rootID, bounds: bounds).cells
        for c in after where c.node.flatMap({ hues[$0] }) != nil {
            #expect(hues[c.node!] == c.hue)
        }
        // A second rescan with no changes keeps every id.
        await s.rescan([a])
        #expect(s.node(atPath: f.path("a/sub/new")) == new)
        #expect(s.node(atPath: f.path("a/keep")) == keep)
    }

    @Test func rescanOfSeveralTargetsInOneWalk() async throws {
        let f = try Fixture()
        let orig = try f.file("a/orig", bytes: 40_000)
        try f.file("a/sub/x", bytes: 1000)
        try f.file("b/y", bytes: 2000)
        try f.file("c/z", bytes: 3000)
        try f.file("top", bytes: 4000)
        let s = await f.scan()
        let a = try #require(s.node(atPath: f.path("a")))
        let b = try #require(s.node(atPath: f.path("b")))
        let c = try #require(s.node(atPath: f.path("c")))
        let sub = try #require(s.node(atPath: f.path("a/sub")))
        let top = try #require(s.node(atPath: f.path("top")))
        // A hard link across two targets, a new file, a vanished target and a file target.
        #expect(link(orig, f.path("b/link")) == 0)
        try f.file("a/sub/new", bytes: 50_000)
        try FileManager.default.removeItem(atPath: f.path("c"))
        try f.file("top", bytes: 80_000)
        await s.rescan([a, b, c, top, sub])
        #expect(s.node(atPath: f.path("a")) == a)
        #expect(s.node(atPath: f.path("a/sub")) == sub)
        #expect(s.node(atPath: f.path("b")) == b)
        #expect(s.node(atPath: f.path("top")) == top)
        #expect(!s.isAlive(c))
        #expect(s.node(atPath: f.path("a/sub/new")) != nil)
        #expect(s.info(top)!.size >= 80_000)
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
        #expect(s.info(s.rootID)!.dirCount == 4)
        #expect(!s.info(a)!.flags.contains(.scanning))
        #expect(!s.info(b)!.flags.contains(.scanning))
        #expect(s.info(s.rootID)!.itemCount == 6)
    }

    @Test func rescanKeepsHardLinkDedupe() async throws {
        let f = try Fixture()
        let orig = try f.file("x/orig", bytes: 40_000)
        try f.dir("y")
        #expect(link(orig, f.path("y/l")) == 0)
        let s = await f.scan()
        await s.rescan([s.node(atPath: f.path("y"))!])
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
        await s.rescan([s.node(atPath: f.path("x"))!])
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
    }

    @Test func prioritizeKeepsTotals() async throws {
        let f = try Fixture()
        for i in 0..<20 { for j in 0..<10 { try f.file("d\(i)/e\(j)/f", bytes: 1000 * (i + 1)) } }
        let plain = await f.scan(workers: 1)
        let s = ScanSession(root: f.root, workerCount: 1)
        s.start()
        for i in stride(from: 19, through: 0, by: -1) {
            if let id = s.node(atPath: f.path("d\(i)")) { s.prioritize(id) }
        }
        await s.waitUntilFinished()
        #expect(s.info(s.rootID)!.size == plain.info(plain.rootID)!.size)
        #expect(s.info(s.rootID)!.itemCount == 200)
        #expect(s.info(s.rootID)!.size == (try duBytes(f.root.path)))
    }

    @Test func prioritizedSubtreeFinishesFirst() async throws {
        let f = try Fixture()
        for i in 0..<60 { for j in 0..<20 { try f.file("d\(i)/e\(j)/f", bytes: 10) } }
        let s = ScanSession(root: f.root, workerCount: 1)
        s.start()
        // Wait until the top level is known, then ask for the last directory.
        #expect(await eventually(every: .milliseconds(1)) { s.node(atPath: f.path("d59")) != nil })
        let target = try #require(s.node(atPath: f.path("d59")))
        s.prioritize(target)
        var wasDoneWhileRootScanning = false
        while !s.progress.finished {
            if let i = s.info(target), !i.flags.contains(.scanning), s.info(s.rootID)!.flags.contains(.scanning) {
                wasDoneWhileRootScanning = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        s.cancel()
        await s.waitUntilFinished()
        #expect(wasDoneWhileRootScanning || s.info(target)!.itemCount == 20)
    }

    @Test func cancelStopsPromptly() async throws {
        let f = try Fixture()
        for i in 0..<40 { for j in 0..<10 { try f.file("d\(i)/e\(j)/f", bytes: 10) } }
        let s = ScanSession(root: f.root, workerCount: 2)
        s.start()
        s.cancel()
        await s.waitUntilFinished()
        #expect(s.progress.finished)
        #expect(s.progress.files < 400)
        var p1 = s.progress
        let size1 = s.info(s.rootID)!.size
        try await Task.sleep(for: .milliseconds(200))
        var p2 = s.progress
        p1.currentPath = ""; p2.currentPath = ""
        #expect(p2 == p1)
        #expect(s.info(s.rootID)!.size == size1)
    }

    @Test func eventsAreCoalescedAndEndWithFinished() async throws {
        let f = try Fixture()
        for i in 0..<30 { for j in 0..<10 { try f.file("d\(i)/e\(j)/f", bytes: 10) } }
        let s = ScanSession(root: f.root, workerCount: 4)
        s.start()
        var changed = 0
        var sawFinished = false
        for await e in s.events {
            switch e {
            case .changed: changed += 1
            case .finished: sawFinished = true
            case .progress: break
            }
        }
        #expect(sawFinished)
        #expect(changed >= 1 && changed < 20)
    }

    @Test func layoutAndBreadcrumb() async throws {
        let f = try Fixture()
        try f.file("a/b/c", bytes: 20_000)
        try f.file("a/d", bytes: 30_000)
        let s = await f.scan()
        let c = try #require(s.node(atPath: f.path("a/b/c")))
        #expect(s.ancestors(of: c).count == 4)
        #expect(s.ancestors(of: c).first == s.rootID)
        #expect(s.info(c)!.parent == s.node(atPath: f.path("a/b")))
        let l = s.layout(viewRoot: s.rootID, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(l.cells.first?.node == s.rootID)
        #expect(l.cells.count >= 3)
    }

    @Test func staysOnVolumeAndSkipsDataFirmlink() async throws {
        // Scanning "/" must not walk /System/Volumes/Data (counted via firmlinks instead).
        let s = ScanSession(root: URL(fileURLWithPath: "/"), workerCount: 2)
        s.start()
        _ = await eventually(2, every: .milliseconds(10)) {
            s.node(atPath: "/System") != nil && s.node(atPath: "/System/Volumes/Data") != nil
        }
        s.prioritize(s.rootID)
        if let data = s.node(atPath: "/System/Volumes/Data") {
            #expect(s.info(data)!.flags.contains(.mountPoint))
            #expect(s.children(of: data).isEmpty)
            s.cancel()
            await s.waitUntilFinished()
            await s.rescan([data])  // must not walk the other volume
            #expect(s.children(of: data).isEmpty)
            #expect(s.info(data)!.flags.contains(.mountPoint))
        } else {
            s.cancel()
            await s.waitUntilFinished()
        }
    }

    @Test func longNamesAreKept() async throws {
        let f = try Fixture()
        let n = String(repeating: "あ", count: 100)  // 300 UTF-8 bytes
        try f.file(n, bytes: 1_000)
        try f.file("d/\(n)/\(n)", bytes: 2_000)
        let s = await f.scan()
        #expect(s.node(atPath: f.path(n)) != nil)
        #expect(s.node(atPath: f.path("d/\(n)/\(n)")) != nil)
        #expect(s.info(s.rootID)!.size >= 3_000)
    }
}
