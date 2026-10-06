import SwiftUI

@main
struct TreemapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Welcome to Treemap", id: "start") {
            StartView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Treemap", for: URL.self) { $url in
            if let url { ScanWindowView(url: url) }
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { AppCommands() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedExternally = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `make run ARGS=/path` and `TREEMAP_ROOT` pass the folder as an argument or variable.
        var paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && $0.hasPrefix("/") }
        if let r = DebugEnv.current.root { paths.append(r) }
        for p in paths where FileManager.default.fileExists(atPath: p) {
            openedExternally = true
            AppRouter.shared.open(URL(fileURLWithPath: p))
        }
        // AppKit delivers the launch's open-documents event (Dock drop, `open -a`, Finder) before
        // this call, so `openedExternally` is final here. SwiftUI does not forward
        // `applicationShouldOpenUntitledFile`, so this is the place to decide. A later open event
        // still works: `AppRouter.open` closes the start window.
        if !openedExternally { AppRouter.shared.showStart() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedExternally = true
        for u in urls { AppRouter.shared.open(u) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppRouter.shared.showStart() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Debug switches from `TREEMAP_*` environment variables, read once.
struct DebugEnv: Sendable {
    /// TREEMAP_ROOT: folder to open at launch.
    let root: String?
    /// TREEMAP_NO_WATCH: no FSEvents live updates (set, whatever its value).
    let noWatch: Bool

    static let current = DebugEnv(ProcessInfo.processInfo.environment)

    init(_ env: [String: String]) {
        root = env["TREEMAP_ROOT"]
        noWatch = env["TREEMAP_NO_WATCH"] != nil
    }
}
