import SwiftUI
import TreemapCore

extension FocusedValues {
    @Entry var scanModel: ScanModel?
    @Entry var inspectorShown: Binding<Bool>?
}

/// Layout "A": map fills the window; toolbar on top, inspector on the right,
/// tray + status bar at the bottom.
struct ScanWindowView: View {
    @State private var model: ScanModel
    @AppStorage("inspectorShown") private var inspectorShown = true

    init(url: URL) {
        _model = State(initialValue: ScanModel(url: url))
    }

    var body: some View {
        MapHost(model: model)
            .frame(minWidth: 480, minHeight: 320)
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.showsFDABanner { FDABanner(model: model) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar(model: model) }
            .inspector(isPresented: $inspectorShown) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 420)
            }
            .toolbar { ScanToolbar(model: model, inspectorShown: $inspectorShown) }
            // The window title stays set (Mission Control, Window menu, tabs); the breadcrumb leads the toolbar.
            .navigationTitle(model.rootName)
            .navigationSubtitle(model.rootPath)
            .toolbar(removing: .title)
            .focusedSceneValue(\.scanModel, model)
            .focusedSceneValue(\.inspectorShown, $inspectorShown)
            .background(WindowAccessor { window in
                window.tabbingMode = .preferred
                window.tabbingIdentifier = "one.m8n.treemap.scan"
                window.titleVisibility = .hidden
                model.onRootGone = { [weak window] in window?.close() }
                if DebugEnv.current.shot, let screen = window.screen ?? NSScreen.main {
                    window.setFrame(NSRect(x: 100, y: screen.frame.maxY - 100 - 800, width: 1300, height: 800), display: true)
                }
                model.shutdown(whenClosing: window)
            })
            .task { model.start() }
            .sheet(item: $model.trashRequest) { req in
                TrashSheet(request: req, onCancel: { model.trashRequest = nil }, onConfirm: { model.confirmTrash(req) })
            }
            .alert("Some items could not be moved to the Trash", isPresented: Binding(
                get: { model.failureMessage != nil }, set: { if !$0 { model.failureMessage = nil } })
            ) {
                Button("OK") { model.failureMessage = nil }
            } message: {
                Text(model.failureMessage ?? "")
            }
    }
}

// MARK: Toolbar

struct ScanToolbar: ToolbarContent {
    let model: ScanModel
    @Binding var inspectorShown: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canBack)
                .help("Back (⌘[)")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canForward)
                .help("Forward (⌘])")
        }
        ToolbarItem(placement: .navigation) {
            BreadcrumbBar(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(!model.canRescan)
                .help("Rescan (⌘R)")
            Button { inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

struct BreadcrumbBar: View {
    let model: ScanModel
    private let maxVisible = 4

    var body: some View {
        let crumbs = model.breadcrumb
        let hidden = crumbs.count > maxVisible ? Array(crumbs.dropLast(maxVisible)) : []
        let visible = crumbs.count > maxVisible ? Array(crumbs.suffix(maxVisible)) : crumbs
        HStack(spacing: 4) {
            if !hidden.isEmpty {
                Menu {
                    ForEach(hidden.reversed()) { c in
                        Button("\(c.name)  \(Fmt.bytes(c.size))") { model.navigateBreadcrumb(c.id) }
                    }
                } label: {
                    Text("…")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                chevron
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, c in
                if index > 0 { chevron }
                let isLast = index == visible.count - 1
                Button { model.navigateBreadcrumb(c.id) } label: {
                    HStack(spacing: 4) {
                        Text(c.name).lineLimit(1).fontWeight(isLast ? .semibold : .regular)
                        Text(Fmt.bytes(c.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLast)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
    }
}

// MARK: Full Disk Access banner

struct FDABanner: View {
    let model: ScanModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("\(model.rootInfo?.unreadableCount ?? model.progress.errors) folders could not be read. Grant Full Disk Access to see everything.")
                .lineLimit(1)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Button { model.dismissFDABanner() } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: Bottom bar

struct BottomBar: View {
    let model: ScanModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.trayInfos.isEmpty {
                TrayBar(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            StatusBar(model: model)
        }
    }
}

struct TrayBar: View {
    let model: ScanModel

    var body: some View {
        HStack(spacing: 10) {
            Label("Reclaim tray", systemImage: "tray.full")
                .font(.headline)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.trayInfos, id: \.id) { info in
                        TrayChip(info: info) { model.removeFromTray([info.id]) }
                    }
                }
                .padding(.vertical, 2)
            }
            Text("up to \(Fmt.bytes(model.trayTotal))")
                .monospacedDigit()
                .fontWeight(.medium)
                .fixedSize()
            Button(role: .destructive) { model.requestTrashTray() } label: {
                Label("Trash", systemImage: "trash")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .help("Move the tray to the Trash (⌘⌫)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct TrayChip: View {
    let info: NodeInfo
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(info.name).lineLimit(1)
            Text(Fmt.bytes(info.size)).foregroundStyle(.secondary).monospacedDigit()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from tray")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

struct StatusBar: View {
    let model: ScanModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning || model.rescanCount > 0 {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            text
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var text: some View {
        let p = model.progress
        if model.isScanning {
            Text("scanning… \(Fmt.compact(p.files)) files · \(Fmt.compact(p.directories)) dirs · \(Fmt.bytes(p.bytes)) · \(p.currentPath)")
                .monospacedDigit()
        } else if model.rescanCount > 0 {
            Text("rescanning…")
        } else if let note = model.note {
            Text(note).foregroundStyle(.primary)
        } else {
            // Totals come from the tree, so they stay right after rescans and trashing.
            let files = model.rootInfo?.itemCount ?? p.files
            let dirs = model.rootInfo?.dirCount ?? p.directories
            let total = model.rootInfo?.size ?? p.bytes
            let unreadable = model.rootInfo?.unreadableCount ?? p.errors
            Text("\(files.formatted()) files · \(dirs.formatted()) dirs · \(Fmt.bytes(total)) · \(unreadable.formatted()) unreadable")
                .monospacedDigit()
        }
    }
}

// MARK: Trash confirmation

struct TrashSheet: View {
    let request: ScanModel.TrashRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(request.items.count) item\(request.items.count == 1 ? "" : "s") to the Trash?")
                .font(.headline)
            List(request.items, id: \.id) { item in
                HStack {
                    Image(nsImage: FileIcon.image(forPath: item.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).lineLimit(1)
                        Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(Fmt.size(item)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(height: min(CGFloat(request.items.count) * 40 + 8, 260))
            .listStyle(.bordered)
            Text("Up to \(Fmt.bytes(request.total)) will be freed when the Trash is emptied. Nothing is deleted permanently.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
