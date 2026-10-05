import AppKit
import SwiftUI

/// Opens scan windows and the start window from anywhere (delegate, menu, start view).
/// SwiftUI's `openWindow` only exists inside scene/view bodies; `AppCommands` installs it here.
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    private var queue: [@MainActor () -> Void] = []

    func install(open: OpenWindowAction, dismiss: DismissWindowAction) {
        guard openWindow == nil else { return }
        openWindow = open
        dismissWindow = dismiss
        let pending = queue
        queue = []
        for job in pending { job() }
    }

    private func run(_ job: @escaping @MainActor () -> Void) {
        if openWindow == nil { queue.append(job) } else { job() }
    }

    /// Opens a scan window for `url` (a directory; a file opens its folder) and closes the start window.
    func open(_ url: URL) {
        var u = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue { u.deleteLastPathComponent() }
        run { [self] in
            openWindow?(value: u)
            dismissWindow?(id: "start")
            NSApp.activate()
        }
    }

    func showStart() {
        run { [self] in
            openWindow?(id: "start")
            NSApp.activate()
        }
    }
}

/// Recently scanned roots, newest first, at most 10.
enum RecentRoots {
    private static let key = "recentRoots"
    static let limit = 10

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        UserDefaults.standard.set(paths, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

@MainActor
enum Opener {
    static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { AppRouter.shared.open(url) }
    }
}
