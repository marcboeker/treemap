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
        switch DebugEnv.current.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
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

/// Debug and screenshot switches from `TREEMAP_*` environment variables, read once.
/// Flags are on when the variable is set, whatever its value.
struct DebugEnv: Sendable {
    /// TREEMAP_DEBUG_STATE: after the scan, select the largest child and tray the next two.
    let state: Bool
    /// TREEMAP_DEBUG_ZOOM: with `state`, also zoom into the selection.
    let zoom: Bool
    /// TREEMAP_DEBUG_TRASH: with `state`, "sheet" opens the trash sheet, "confirm" also confirms it.
    let trash: String?
    /// TREEMAP_SHOT: fixed window frame for screenshots.
    let shot: Bool
    /// TREEMAP_NO_WATCH: no FSEvents live updates.
    let noWatch: Bool
    /// TREEMAP_DEBUG: label statistics on stderr.
    let debug: Bool
    /// TREEMAP_STATS: frame statistics on stderr.
    let stats: Bool
    /// TREEMAP_APPEARANCE: "dark" or "light".
    let appearance: String?
    /// TREEMAP_ROOT: folder to open at launch.
    let root: String?

    static let current = DebugEnv(ProcessInfo.processInfo.environment)

    init(_ env: [String: String]) {
        state = env["TREEMAP_DEBUG_STATE"] != nil
        zoom = env["TREEMAP_DEBUG_ZOOM"] != nil
        trash = env["TREEMAP_DEBUG_TRASH"]
        shot = env["TREEMAP_SHOT"] != nil
        noWatch = env["TREEMAP_NO_WATCH"] != nil
        debug = env["TREEMAP_DEBUG"] != nil
        stats = env["TREEMAP_STATS"] != nil
        appearance = env["TREEMAP_APPEARANCE"]
        root = env["TREEMAP_ROOT"]
    }
}
