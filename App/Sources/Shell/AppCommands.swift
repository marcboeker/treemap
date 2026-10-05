import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusedValue(\.scanModel) private var model
    @FocusedValue(\.inspectorShown) private var inspector

    var body: some Commands {
        let _ = AppRouter.shared.install(open: openWindow, dismiss: dismissWindow)

        CommandGroup(after: .appInfo) {
            Button("Install Command Line Tool…") { CommandLineTool.install() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") { AppRouter.shared.showStart() }
                .keyboardShortcut("n")
            Button("Open Folder…") { Opener.chooseFolder() }
                .keyboardShortcut("o")
            Divider()
            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r")
                .disabled(model?.canRescan != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Path") { model?.copySelectionPaths() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model?.hasSelection != true)
        }

        CommandGroup(replacing: .sidebar) {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.canBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.canForward != true)
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model?.canZoomOut != true)
            Divider()
            Button((inspector?.wrappedValue ?? true) ? "Hide Inspector" : "Show Inspector") {
                inspector?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(inspector == nil)
            Button((model?.drawHidden ?? true) ? "Hide Hidden Items" : "Show Hidden Items") { model?.toggleDrawHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandMenu("Item") {
            Button("Zoom In") { model?.zoomInSelection() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model?.selection.count != 1)
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model?.hasSelection != true)
            Button("Reveal in Finder") { model?.revealSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.hasSelection != true)
            Button("Quick Look") { model?.toggleQuickLook() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model?.hasSelection != true)
            Divider()
            Button("Add to Tray") { model?.addSelectionToTray() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model?.hasSelection != true)
            Button("Clear Tray") { model?.clearTray() }
                .disabled(model?.trayInfos.isEmpty != false)
            Button("Move to Trash…") { model?.requestTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model == nil || (model?.hasSelection != true && model?.trayInfos.isEmpty != false))
        }
    }
}
