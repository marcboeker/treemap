import AppKit
import Observation
import TreemapCore

/// State of one scan window. Owns the `ScanSession` (created in `start()`, cancelled in
/// `shutdown()`), the zoom history, selection, tray and the Metal map view.
///
/// Threading: everything here runs on the main actor. The session is thread-safe; layouts
/// are computed in a detached task and applied on main (stale results are not applied).
@MainActor @Observable
final class ScanModel {
    struct Crumb: Identifiable, Hashable {
        let id: NodeID
        let name: String
        let size: Int64
    }

    struct TrashRequest: Identifiable {
        let id = UUID()
        var items: [NodeInfo]
        var total: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    struct TrashOutcome: Sendable {
        var trashed: [NodeID] = []
        var failures: [String] = []
    }

    // MARK: Observable state

    let url: URL
    let rootName: String
    let rootPath: String
    private(set) var viewRoot = NodeID(raw: 0)
    private(set) var breadcrumb: [Crumb] = []
    private(set) var selectionInfos: [NodeInfo] = []
    private(set) var trayInfos: [NodeInfo] = []
    private(set) var hoverInfo: NodeInfo?
    private(set) var progress = ScanProgress()
    private(set) var isScanning = true
    private(set) var rescanCount = 0
    /// Full Disk Access is missing and the root contains protected folders.
    private(set) var fdaDenied = false
    private(set) var fdaBannerDismissed = false
    private(set) var rootInfo: NodeInfo?
    private(set) var note: String?
    private(set) var backStack: [NodeID] = []
    private(set) var forwardStack: [NodeID] = []
    private(set) var selection: Set<NodeID> = []
    private(set) var tray: [NodeID] = []
    var trashRequest: TrashRequest?
    var failureMessage: String?

    var canBack: Bool { !backStack.isEmpty }
    var canForward: Bool { !forwardStack.isEmpty }
    var canZoomOut: Bool { viewRoot != rootID }
    var canRescan: Bool { !isScanning && session != nil }
    var hasSelection: Bool { !selection.isEmpty }
    var trayTotal: Int64 { total(trayInfos) }
    var drawHidden: Bool { options.drawHidden }

    /// Items the inspector shows: the hovered cell, else the selection.
    var inspectorInfos: [NodeInfo] { hoverInfo.map { [$0] } ?? selectionInfos }
    var inspectorIsHover: Bool { hoverInfo != nil }

    // MARK: Plumbing

    @ObservationIgnored private(set) var session: ScanSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Called when the watched root vanished; the window decides what to do (it closes).
    @ObservationIgnored var onRootGone: (@MainActor () -> Void)?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var focus: NodeID?
    /// Observed: `drawHidden` (menu title) reads it.
    private var options = LayoutOptions()
    @ObservationIgnored private var layoutBusy = false
    @ObservationIgnored private var layoutDirty = false
    @ObservationIgnored private var layoutAnimate = false
    @ObservationIgnored private var swipeMonitor: Any?
    @ObservationIgnored private let quickLook = QuickLookController()
    @ObservationIgnored private var mapConfigured = false
    @ObservationIgnored lazy var map = TreemapMapView()

    private var rootID: NodeID { session?.rootID ?? NodeID(raw: 0) }

    init(url: URL) {
        self.url = url.standardizedFileURL
        let path = self.url.path
        rootPath = path
        // Finder's name: the volume name for "/", localized folder names.
        rootName = FileManager.default.displayName(atPath: path)
    }

    // MARK: Lifecycle

    func start() {
        guard session == nil else { return }
        let s = ScanSession(root: url)
        session = s
        RecentRoots.add(url)
        eventsTask = Task { [weak self] in
            for await event in s.events {
                guard let self else { break }
                handle(event)
            }
        }
        s.start()
        refreshDerived()
        startWatching(s)
        probeFullDiskAccess()
    }

    /// Live updates: FSEvents on the root; rescans happen in Core, the model re-reads afterwards.
    private func startWatching(_ s: ScanSession) {
        if DebugEnv.current.noWatch { return }
        let w = FileWatcher(session: s)
        watcher = w
        w.start()
        watchTask = Task { [weak self] in
            for await event in w.events {
                guard let self else { break }
                switch event {
                case .updated:
                    afterRescan(animated: false)
                case .rootGone:
                    onRootGone?()
                }
            }
        }
    }

    // MARK: Full Disk Access

    func dismissFDABanner() { fdaBannerDismissed = true }

    var showsFDABanner: Bool { fdaDenied && !fdaBannerDismissed }

    /// Probes a TCC-protected folder, only for roots that contain one.
    private func probeFullDiskAccess() {
        let home = NSHomeDirectory()
        let candidates: Set<String> = ["/", "/Users", home, home + "/Library"]
        guard candidates.contains(rootPath) else { return }
        Task { [weak self] in
            let denied = await Task.detached(priority: .utility) { Self.fullDiskAccessDenied(home: home) }.value
            self?.fdaDenied = denied
        }
    }

    /// EPERM from a protected folder means no Full Disk Access. A missing folder says nothing.
    nonisolated static func fullDiskAccessDenied(home: String) -> Bool {
        for sub in ["Library/Mail", "Library/Safari", "Library/Messages", "Library/Application Support/AddressBook"] {
            let fd = Darwin.open(home + "/" + sub, O_RDONLY)
            if fd >= 0 { close(fd); return false }
            if errno == EPERM || errno == EACCES { return true }
        }
        return false
    }

    /// Shuts the session down when `window` closes. The window accessor can call this more
    /// than once; each call replaces the previous observer.
    func shutdown(whenClosing window: NSWindow) {
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func shutdown() {
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        watcher?.stop()
        watchTask?.cancel()
        session?.cancel()
        eventsTask?.cancel()
        quickLook.close()
        if let m = swipeMonitor { NSEvent.removeMonitor(m); swipeMonitor = nil }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .changed:
            refreshDerived()
            requestLayout()
        case .progress(let p):
            progress = p
        case .finished:
            isScanning = false
            if let s = session { progress = s.progress }
            refreshDerived()
            requestLayout()
            if DebugEnv.current.state { applyDebugState() }
        }
    }

    /// Screenshot helper: select the largest child and tray the next two.
    private func applyDebugState() {
        guard let s = session else { return }
        let kids = s.children(of: viewRoot)
        guard kids.count >= 3 else { return }
        setSelection([kids[0]])
        for id in kids[1...2] { addToTray([id]) }
        if DebugEnv.current.zoom { zoomIn(kids[0]) }
        switch DebugEnv.current.trash {
        case "sheet": requestTrash()
        case "confirm": requestTrash(); if let r = trashRequest { confirmTrash(r) }
        default: break
        }
    }

    // MARK: Map wiring

    func configureMap() {
        guard !mapConfigured else { return }
        mapConfigured = true
        map.onResize = { [weak self] size in
            guard let self, size.width > 10, size.height > 10 else { return }
            requestLayout()
        }
        map.onHoverChange = { [weak self] cell in self?.hoverChanged(cell) }
        map.onClick = { [weak self] cell, mods in self?.clicked(cell, mods) }
        map.onDoubleClick = { [weak self] cell in self?.doubleClicked(cell) }
        map.onContextMenu = { [weak self] id, event in self?.showContextMenu(id, event) }
        map.onKeyCommand = { [weak self] command in self?.handleKey(command) }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .otherMouseDown]) { [weak self] event in
            let isSwipe = event.type == .swipe
            let dx = event.deltaX
            let button = event.buttonNumber
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let w = self.map.window, w.windowNumber == windowNumber else { return false }
                if isSwipe {
                    // deltaX > 0 is a swipe to the right in AppKit's convention: back (Safari).
                    if dx > 0 { self.goBack() } else if dx < 0 { self.goForward() }
                    return true
                }
                if button == 3 { self.goBack(); return true }
                if button == 4 { self.goForward(); return true }
                return false
            }
            return consumed ? nil : event
        }
        requestLayout()
    }

    /// Queues a layout for the current view root and map size. At most one layout runs at a time;
    /// requests that arrive meanwhile collapse into one follow-up.
    func requestLayout(animated: Bool = true) {
        layoutAnimate = layoutAnimate || animated
        layoutDirty = true
        pumpLayout()
    }

    private func pumpLayout() {
        guard !layoutBusy, layoutDirty, let session else { return }
        let size = map.bounds.size
        guard size.width > 10, size.height > 10 else { return }
        layoutBusy = true
        layoutDirty = false
        let animated = layoutAnimate
        layoutAnimate = false
        let root = viewRoot
        let opts = options
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                session.layout(viewRoot: root, bounds: CGRect(origin: .zero, size: size), options: opts)
            }.value
            guard let self else { return }
            layoutBusy = false
            if result.root == viewRoot, result.bounds.size == map.bounds.size {
                map.setLayout(result, animated: animated)
            } else {
                layoutDirty = true
                layoutAnimate = layoutAnimate || animated
            }
            pumpLayout()
        }
    }

    // MARK: Derived state

    private func info(_ id: NodeID) -> NodeInfo? { session?.info(id) }

    /// Assigns only when the value changes, so the 10 Hz refresh does not wake every observer.
    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<ScanModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Re-reads everything the UI shows from the session; drops ids that no longer exist.
    func refreshDerived() {
        guard let s = session else { return }
        update(\.rootInfo, s.info(s.rootID))
        if !s.isAlive(viewRoot) {
            // View root vanished (trashed or rescanned away): nearest existing ancestor.
            viewRoot = s.nearestLiveAncestor(of: viewRoot) ?? s.rootID
            requestLayout()
        }
        let crumbs = s.ancestors(of: viewRoot).compactMap { id in
            info(id).map { Crumb(id: id, name: id == s.rootID ? rootName : $0.name, size: $0.size) }
        }
        update(\.breadcrumb, crumbs)
        update(\.backStack, backStack.filter(s.isAlive))
        update(\.forwardStack, forwardStack.filter(s.isAlive))
        setSelection(selection.filter(s.isAlive))
        setTray(tray.filter(s.isAlive))
        if let h = hoverInfo { update(\.hoverInfo, info(h.id)) }
    }

    private func setSelection(_ ids: Set<NodeID>) {
        update(\.selection, ids)
        map.selected = ids
        update(\.selectionInfos, ids.compactMap(info).sorted { $0.size > $1.size })
        quickLook.update(selectionInfos.map(\.url))
    }

    private func setTray(_ ids: [NodeID]) {
        update(\.tray, ids)
        map.tray = Set(ids)
        update(\.trayInfos, ids.compactMap(info))
    }

    /// Drops dead items and items that sit below another item of the list, so sizes are not
    /// counted twice. Order is shallowest first.
    private func topLevel(_ infos: [NodeInfo]) -> [NodeInfo] {
        guard let s = session else { return infos }
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return s.topLevel(infos.map(\.id)).compactMap { byID[$0] }
    }

    /// Size of `infos` with nested items counted once (tray, multi-selection).
    func total(_ infos: [NodeInfo]) -> Int64 {
        topLevel(infos).reduce(0) { $0 + $1.size }
    }

    // MARK: Mouse

    /// The map reports nil for the view root and aggregate cells.
    private func hoverChanged(_ id: NodeID?) {
        update(\.hoverInfo, id.flatMap(info))
    }

    private func clicked(_ id: NodeID?, _ mods: NSEvent.ModifierFlags) {
        guard let id, id != viewRoot else {
            if mods.isDisjoint(with: [.command, .shift]) { setSelection([]) }
            return
        }
        focus = id
        if mods.contains(.command) || mods.contains(.shift) {
            var s = selection
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            setSelection(s)
        } else {
            setSelection([id])
        }
    }

    private func doubleClicked(_ id: NodeID) {
        guard id != viewRoot, let i = info(id) else { return }
        if i.flags.contains(.mountPoint) {
            AppRouter.shared.open(i.url)
        } else {
            zoomIn(id)
        }
    }

    // MARK: Zoom

    func zoomIn(_ id: NodeID) {
        guard let i = info(id), i.isDirectory, !i.flags.contains(.mountPoint), id != viewRoot else { return }
        session?.prioritize(id)
        navigate(to: id, record: true)
        setSelection([])
    }

    func zoomInSelection() {
        if selection.count == 1, let id = selection.first { zoomIn(id) }
    }

    func zoomOut() {
        guard let p = info(viewRoot)?.parent else { return }
        let left = viewRoot
        navigate(to: p, record: true)
        setSelection([left])
        focus = left
    }

    func navigate(to id: NodeID, record: Bool) {
        guard id != viewRoot, session?.isAlive(id) == true else { return }
        if record {
            backStack.append(viewRoot)
            forwardStack = []
        }
        setViewRoot(id)
    }

    func goBack() {
        guard let id = step(from: &backStack, to: &forwardStack) else { return }
        session?.prioritize(id)
        setViewRoot(id)
    }

    func goForward() {
        guard let id = step(from: &forwardStack, to: &backStack) else { return }
        session?.prioritize(id)
        setViewRoot(id)
    }

    /// History step: pops the newest live id off `from` (dead ones are dropped on the way)
    /// and pushes the current view root onto `to`. Nil when `from` has no live id.
    private func step(from: inout [NodeID], to: inout [NodeID]) -> NodeID? {
        guard let s = session else { return nil }
        while let id = from.popLast() {
            guard s.isAlive(id) else { continue }
            to.append(viewRoot)
            return id
        }
        return nil
    }

    private func setViewRoot(_ id: NodeID) {
        viewRoot = id
        hoverInfo = nil
        refreshDerived()
        requestLayout(animated: true)
    }

    func navigateBreadcrumb(_ id: NodeID) { navigate(to: id, record: true) }

    // MARK: Keys

    /// Navigation keys from the map. Command shortcuts are menu items (AppCommands).
    private func handleKey(_ command: TreemapMapView.KeyCommand) {
        switch command {
        case .move(let dir): move(dir)
        case .cancel: if canZoomOut { zoomOut() } else { setSelection([]) }
        case .enter: zoomInSelection()
        }
    }

    /// Moves the selection to the nearest sibling cell in `dir`.
    private func move(_ dir: TreemapMapView.Direction) {
        guard let cells = map.layout?.cells, !cells.isEmpty else { return }
        let base = focus.flatMap { f in selection.contains(f) ? f : nil } ?? selection.first
        guard let base, let bi = cells.firstIndex(where: { $0.node == base }) else {
            // Nothing selected: start with the largest child of the view root.
            let first = cells.filter { $0.parent == 0 && $0.node != nil }.max { $0.size < $1.size }
            if let id = first?.node { focus = id; setSelection([id]) }
            return
        }
        let b = cells[bi]
        let br = b.rect
        var best: (score: CGFloat, id: NodeID)?
        for c in cells where c.parent == b.parent && c.node != b.node {
            guard let id = c.node else { continue }
            let r = c.rect
            let along: CGFloat, cross: CGFloat
            switch dir {
            case .right: along = r.midX - br.midX; cross = abs(r.midY - br.midY)
            case .left: along = br.midX - r.midX; cross = abs(r.midY - br.midY)
            case .down: along = r.midY - br.midY; cross = abs(r.midX - br.midX)
            case .up: along = br.midY - r.midY; cross = abs(r.midX - br.midX)
            }
            guard along > 0.5 else { continue }
            let score = along + 2.5 * cross
            if best == nil || score < best!.score { best = (score, id) }
        }
        if let best { focus = best.id; setSelection([best.id]) }
    }

    // MARK: Actions

    func open(_ infos: [NodeInfo]) {
        for i in infos { NSWorkspace.shared.open(i.url) }
    }

    func openSelection() { open(selectionInfos) }

    func reveal(_ infos: [NodeInfo]) {
        let urls = infos.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func revealSelection() { reveal(selectionInfos) }

    func copyPaths(_ infos: [NodeInfo]) {
        guard !infos.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(infos.map(\.path).joined(separator: "\n"), forType: .string)
        flash("Copied \(infos.count == 1 ? "path" : "\(infos.count) paths")")
    }

    func copySelectionPaths() { copyPaths(selectionInfos) }

    func toggleQuickLook() {
        quickLook.toggle(selectionInfos.map(\.url))
    }

    func toggleDrawHidden() {
        options.drawHidden.toggle()
        requestLayout()
    }

    func addToTray(_ ids: [NodeID]) {
        guard let s = session else { return }
        var t = tray
        for id in ids where id != rootID && !t.contains(id) && s.isAlive(id) { t.append(id) }
        setTray(t)
    }

    func addSelectionToTray() { addToTray(selectionInfos.map(\.id)) }

    func removeFromTray(_ ids: [NodeID]) { setTray(tray.filter { !ids.contains($0) }) }

    func clearTray() { setTray([]) }

    func isInTray(_ id: NodeID) -> Bool { tray.contains(id) }

    func toggleTray(_ ids: [NodeID]) {
        if ids.allSatisfy({ tray.contains($0) }) { removeFromTray(ids) } else { addToTray(ids) }
    }

    // MARK: Rescan

    func rescan() {
        guard let s = session, canRescan else { return }
        let targets = selection.isEmpty ? [viewRoot] : Array(selection)
        rescanCount += 1
        Task { [weak self] in
            await s.rescan(targets)
            guard let self else { return }
            rescanCount -= 1
            afterRescan(animated: true)
        }
    }

    /// Re-reads the session after a subtree rescan (manual or live) and lays out again.
    private func afterRescan(animated: Bool) {
        refreshDerived()
        requestLayout(animated: animated)
    }

    // MARK: Trash

    func requestTrash() {
        if !selectionInfos.isEmpty { requestTrash(selectionInfos) }
        else if !trayInfos.isEmpty { requestTrash(trayInfos) }
    }

    func requestTrashTray() { requestTrash(trayInfos) }

    func requestTrash(_ ids: [NodeID]) { requestTrash(ids.compactMap(info)) }

    private func requestTrash(_ infos: [NodeInfo]) {
        let items = topLevel(infos.filter { $0.id != rootID }).sorted { $0.size > $1.size }
        guard !items.isEmpty else { return }
        trashRequest = TrashRequest(items: items)
    }

    func confirmTrash(_ req: TrashRequest) {
        trashRequest = nil
        let entries = req.items.map { (id: $0.id, url: $0.url, name: $0.name, size: $0.size) }
        let sizes = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.size) })
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> TrashOutcome in
                var out = TrashOutcome()
                for e in entries {
                    do {
                        try FileManager.default.trashItem(at: e.url, resultingItemURL: nil)
                        out.trashed.append(e.id)
                    } catch {
                        out.failures.append("\(e.name): \(error.localizedDescription)")
                    }
                }
                return out
            }.value
            self?.finishTrash(outcome, sizes: sizes)
        }
    }

    private func finishTrash(_ outcome: TrashOutcome, sizes: [NodeID: Int64]) {
        if !outcome.trashed.isEmpty {
            session?.remove(outcome.trashed)
            let gone = Set(outcome.trashed)
            setTray(tray.filter { !gone.contains($0) })
            setSelection(selection.subtracting(gone))
            hoverInfo = nil
            refreshDerived()
            requestLayout()
            let freed = outcome.trashed.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            let n = outcome.trashed.count
            flash("Moved \(n) item\(n == 1 ? "" : "s") to Trash — up to \(Fmt.bytes(freed)) will be freed when the Trash is emptied", seconds: 10)
        }
        if !outcome.failures.isEmpty {
            failureMessage = outcome.failures.joined(separator: "\n")
        }
    }

    func flash(_ text: String, seconds: Double = 5) {
        note = text
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.note = nil }
        }
    }

    // MARK: Context menu

    /// Right-click on `hit`: the menu acts on the selection if `hit` is part of it, else on `hit`.
    private func showContextMenu(_ hit: NodeID, _ event: NSEvent) {
        let ids = selection.contains(hit) ? Array(selection) : [hit]
        guard hit != viewRoot || ids.count > 1 else { return }
        if !selection.contains(hit) { setSelection([hit]); focus = hit }
        let infos = ids.compactMap(info)
        guard !infos.isEmpty else { return }
        let single = infos.count == 1 ? infos[0] : nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: @escaping @MainActor () -> Void) {
            let item = ActionMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Open", "arrow.up.forward.app") { [weak self] in self?.open(infos) }
        add("Reveal in Finder", "folder") { [weak self] in self?.reveal(infos) }
        add("Quick Look", "eye") { [weak self] in self?.toggleQuickLook() }
        add("Copy Path", "doc.on.doc") { [weak self] in self?.copyPaths(infos) }
        menu.addItem(.separator())
        let allTrayed = ids.allSatisfy { tray.contains($0) }
        add(allTrayed ? "Remove from Tray" : "Add to Tray", allTrayed ? "tray.and.arrow.up" : "tray.and.arrow.down") { [weak self] in
            self?.toggleTray(ids)
        }
        add("Move to Trash…", "trash") { [weak self] in self?.requestTrash(ids) }
        if let single {
            if single.flags.contains(.mountPoint) {
                menu.addItem(.separator())
                add("Open Mount in New Tab", "plus.rectangle.on.rectangle") { AppRouter.shared.open(single.url) }
            } else if single.isDirectory {
                menu.addItem(.separator())
                add("Zoom In", "plus.magnifyingglass") { [weak self] in self?.zoomIn(single.id) }
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: map)
    }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}
