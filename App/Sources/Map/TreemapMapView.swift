import AppKit
import MetalKit
import QuartzCore
import TreemapCore

/// Metal treemap view. Draws one instanced quad per cell plus label bitmaps from a glyph
/// atlas, on demand (never continuously, except while an animation runs).
///
/// Input is the flat `TreemapLayout`; hover/selection/tray are overlay state. The view never
/// lays out by itself: when it resizes it calls `onResize` and the owner supplies a new layout.
@MainActor
final class TreemapMapView: MTKView {
    // MARK: Callbacks

    // Input callbacks report nodes, never aggregate cells: see `node(at:)`.

    /// The hovered node, or nil. The view root counts as nil.
    var onHoverChange: ((NodeID?) -> Void)?
    /// Click on a node, or nil for empty space and aggregate cells.
    var onClick: ((NodeID?, NSEvent.ModifierFlags) -> Void)?
    /// Double-click on a node: the owner zooms in.
    var onDoubleClick: ((NodeID) -> Void)?
    /// Right-click (or control-click) on a node.
    var onContextMenu: ((NodeID, NSEvent) -> Void)?
    /// Navigation keys (arrows, Esc, keypad Enter) after `interpretKeyEvents`. Command shortcuts
    /// (↩, ⌘↩, Space, ⌫, ⌘⌫, ⌘↑, ...) are menu items in AppCommands, not handled here.
    var onKeyCommand: ((KeyCommand) -> Void)?

    enum KeyCommand {
        case move(Direction)
        /// Esc.
        case cancel
        /// Keypad Enter, or ↩ while its menu item is disabled.
        case enter
    }
    enum Direction { case left, right, up, down }
    var onResize: ((CGSize) -> Void)?

    // MARK: State

    var hovered: NodeID? { didSet { if hovered != oldValue { setNeedsRedraw() } } }
    var selected: Set<NodeID> = [] { didSet { if selected != oldValue { setNeedsRedraw() } } }
    var tray: Set<NodeID> = [] { didSet { if tray != oldValue { setNeedsRedraw() } } }
    /// Height of a directory header strip in points. The owner lays out with default options.
    private let headerHeight = LayoutOptions().headerHeight

    private(set) var layout: TreemapLayout?

    // MARK: Per-layout data (index-parallel with `layout.cells`)

    private var styles: [CellStyle] = []
    private var indexByID: [NodeID: Int] = [:]
    private var hitIndex = CellHitIndex(cells: [])
    private var displayRects: [CGRect] = []
    private var displayAlpha: [Float] = []
    private var labelItems: [LabelItem] = []

    private struct LabelItem {
        enum Anchor: UInt8 { case left, center, right }
        var cell: Int32
        var entry: AtlasEntry
        var anchor: Anchor
        var dx: Float
        var dy: Float
        var color: SIMD4<Float>
        var dim: Bool
    }

    // MARK: Animation

    private struct Animation {
        var start: CFTimeInterval
        var duration: CFTimeInterval
        var from: [CGRect]
        var startAlpha: [Float]
    }
    private struct Ghost {
        var style: CellStyle
        var rect: CGRect
    }
    private var anim: Animation?
    private var ghosts: [Ghost] = []
    private var link: CADisplayLink?
    private var animProgress: Float = 1 // eased, for ghosts
    /// Counts started animations, so the fallback can tell whether its animation still runs.
    private var animGeneration = 0

    // MARK: Metal

    private let queue: MTLCommandQueue
    private let cellPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private var atlas: LabelAtlas
    /// Per-frame buffers (one per in-flight frame): base cells and labels while animating, overlays always.
    private var cellBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var labelBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var overlayBuffers: [MTLBuffer?] = [nil, nil, nil]
    /// Base cells and labels of the current layout when no animation runs; nil when stale.
    private var staticBase: BaseBuffers?
    private var staticScale: Float = 0
    private var slot = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var palette: MapPalette

    // MARK: Input state

    private var trackingArea: NSTrackingArea?
    private var mouseInside = false
    private var lastMouse: CGPoint = .zero

    // MARK: Init

    init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { fatalError("Metal is not available") }
        self.queue = queue
        palette = MapPalette(appearance: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
        atlas = LabelAtlas(device: device, scale: 2)

        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        cellPipeline = pipeline("cellVertex", "cellFragment")
        labelPipeline = pipeline("labelVertex", "labelFragment")

        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        clearColor = palette.background
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Public API

    /// Hit test: the deepest cell containing `point` (view coordinates, top-left origin).
    func cell(at point: CGPoint) -> TreemapCell? {
        guard let cells = layout?.cells else { return nil }
        let hit = hitIndex.cell(at: point, in: cells)
        // Parents precede children, so the last match of a backward scan is the deepest.
        assert(hit == cells.indices.last { cells[$0].rect.contains(point) }, "hit index disagrees with linear scan")
        return hit.map { cells[$0] }
    }

    /// The node under `point`: nil for empty space and for aggregate cells.
    func node(at point: CGPoint) -> NodeID? { cell(at: point)?.node }

    /// Installs a new layout. With `animated`, cells tween from their currently displayed
    /// position (matched by NodeID) to the new one: zooming in/out takes ~250 ms, a live
    /// update of the same root 120 ms.
    func setLayout(_ new: TreemapLayout, animated: Bool) {
        // Bring a running tween to the current time first: if ticks were late, displayRects is stale.
        if anim != nil { applyAnimation(now: CACurrentMediaTime()) }
        let old = layout
        let oldRects = displayRects
        let oldIndex = indexByID
        let oldStyles = styles
        let oldAlpha = displayAlpha

        layout = new
        let heat = HeatScale(cells: new.cells)
        styles = new.cells.map { palette.style(for: $0, heat: heat) }
        indexByID = Dictionary(uniqueKeysWithValues: new.cells.enumerated().compactMap { i, c in c.node.map { ($0, i) } })
        hitIndex = CellHitIndex(cells: new.cells)
        displayRects = new.cells.map(\.rect)
        displayAlpha = [Float](repeating: 1, count: new.cells.count)
        anim = nil
        ghosts = []
        animProgress = 1
        planLabels()
        invalidateStatic()

        if animated, let old, !old.cells.isEmpty, !new.cells.isEmpty, startAnimation(
            old: old, new: new, oldRects: oldRects, oldAlpha: oldAlpha, oldIndex: oldIndex, oldStyles: oldStyles) {
            startLink()
        } else {
            stopLink()
        }
        refreshHover()
        setNeedsRedraw()
    }

    // MARK: Animation

    private func startAnimation(old: TreemapLayout, new: TreemapLayout, oldRects: [CGRect], oldAlpha: [Float],
                                oldIndex: [NodeID: Int], oldStyles: [CellStyle]) -> Bool {
        let sameRoot = old.root == new.root
        let related = sameRoot || oldIndex[new.root] != nil || indexByID[old.root] != nil
        guard related, oldRects.count == old.cells.count else { return false }
        if sameRoot && old.bounds != new.bounds { return false }

        let n = new.cells.count
        var from = [CGRect](repeating: .zero, count: n)
        var a0 = [Float](repeating: 1, count: n)
        var anchor = [Int](repeating: -1, count: n)
        for i in 0..<n {
            if let id = new.cells[i].node, let o = oldIndex[id] {
                // A displayed rect caught mid-tween can be shorter than a header: never go negative.
                let dh = max((new.cells[i].flags.contains(.hasHeader) ? headerHeight : 0)
                    - (old.cells[o].flags.contains(.hasHeader) ? headerHeight : 0), -oldRects[o].height)
                from[i] = oldRects[o]
                from[i].origin.y -= dh
                from[i].size.height += dh
                a0[i] = oldAlpha[o]
                anchor[i] = i
            } else {
                a0[i] = 0
                let p = Int(new.cells[i].parent)
                let a = p >= 0 ? anchor[p] : -1
                anchor[i] = a
                let r = new.cells[i].rect
                if a >= 0 {
                    // Grow out of the matched ancestor: same relative position inside its start rect.
                    let na = new.cells[a].rect, fa = from[a]
                    if na.width > 0, na.height > 0 {
                        from[i] = CGRect(x: fa.minX + (r.minX - na.minX) / na.width * fa.width,
                                         y: fa.minY + (r.minY - na.minY) / na.height * fa.height,
                                         width: r.width / na.width * fa.width,
                                         height: r.height / na.height * fa.height)
                    } else { from[i] = r }
                } else {
                    from[i] = r
                }
            }
        }
        if !sameRoot {
            for (i, c) in old.cells.enumerated() where c.node.flatMap({ indexByID[$0] }) == nil {
                ghosts.append(Ghost(style: oldStyles[i], rect: oldRects[i]))
            }
        }
        anim = Animation(start: CACurrentMediaTime(), duration: sameRoot ? 0.12 : 0.25, from: from, startAlpha: a0)
        applyAnimation(now: anim!.start)
        animGeneration += 1
        finishAnimationLate(generation: animGeneration, after: anim!.duration)
        return true
    }

    /// Fallback for missing display-link ticks: finishes an animation that still runs after its
    /// end, so the map never stays half-tweened.
    private func finishAnimationLate(generation: Int, after duration: CFTimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            guard let self, animGeneration == generation, anim != nil else { return }
            finishAnimation()
            setNeedsRedraw()
        }
    }

    private func applyAnimation(now: CFTimeInterval) {
        guard let a = anim, let cells = layout?.cells else { return }
        let raw = max(0, min(1, (now - a.start) / a.duration))
        let t = Float(raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2)
        animProgress = t
        let tt = CGFloat(t)
        for i in 0..<cells.count {
            let f = a.from[i], r = cells[i].rect
            displayRects[i] = CGRect(x: f.minX + (r.minX - f.minX) * tt, y: f.minY + (r.minY - f.minY) * tt,
                                     width: f.width + (r.width - f.width) * tt, height: f.height + (r.height - f.height) * tt)
            displayAlpha[i] = a.startAlpha[i] + (1 - a.startAlpha[i]) * t
        }
        if raw >= 1 { finishAnimation() }
    }

    private func finishAnimation() {
        anim = nil
        ghosts = []
        animProgress = 1
        if let cells = layout?.cells {
            for i in 0..<cells.count { displayRects[i] = cells[i].rect; displayAlpha[i] = 1 }
        }
        stopLink()
    }

    private func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        applyAnimation(now: CACurrentMediaTime())
        render()
    }

    // MARK: Labels

    private func planLabels() {
        guard let cells = layout?.cells else { labelItems = []; return }
        var items: [LabelItem] = []
        for _ in 0..<2 {
            let epoch = atlas.epoch
            items = buildLabelItems(cells)
            if atlas.epoch == epoch { break }
        }
        labelItems = items
    }

    private func buildLabelItems(_ cells: [TreemapCell]) -> [LabelItem] {
        var items: [LabelItem] = []
        items.reserveCapacity(cells.count)
        let nameH = atlas.lineHeight(.fileName), sizeH = atlas.lineHeight(.size)
        for (i, c) in cells.enumerated() where c.flags.contains(.showsLabel) {
            let r = c.rect
            let st = styles[i]
            let dim = st.dimLabel
            if st.hasHeader {
                guard r.width > 24, r.height >= 10 else { continue }
                // Header row: name left, size right; below the top rule when there is one.
                let hh = min(headerHeight, r.height)
                let rule: CGFloat = st.topRule ? 1 : 0
                var nameMax = r.width - 14
                if let s = atlas.entry(Fmt.bytes(c.size), style: .size, maxWidth: r.width - 14), r.width - 14 > s.size.width + 36 {
                    nameMax = r.width - 14 - s.size.width - 8
                    items.append(LabelItem(cell: Int32(i), entry: s, anchor: .right, dx: 7,
                                           dy: Float((hh - s.size.height) / 2 + rule), color: st.subtext, dim: dim))
                }
                if let e = atlas.entry(c.name, style: c.depth == 1 ? .topDirName : .dirName, maxWidth: nameMax) {
                    items.append(LabelItem(cell: Int32(i), entry: e, anchor: .left, dx: 7,
                                           dy: Float((hh - e.size.height) / 2 + rule), color: st.text, dim: dim))
                }
            } else {
                guard r.height >= nameH + 2, r.width > 20 else { continue }
                let showSize = r.height >= nameH + sizeH + 6
                let total = showSize ? nameH + sizeH : nameH
                let y0 = (r.height - total) / 2
                if let e = atlas.entry(c.name, style: .fileName, maxWidth: r.width - 8) {
                    items.append(LabelItem(cell: Int32(i), entry: e, anchor: .center, dx: 0, dy: Float(y0), color: st.text, dim: dim))
                }
                if showSize, let s = atlas.entry(Fmt.bytes(c.size), style: .size, maxWidth: r.width - 8) {
                    items.append(LabelItem(cell: Int32(i), entry: s, anchor: .center, dx: 0, dy: Float(y0 + nameH), color: st.subtext, dim: dim))
                }
            }
        }
        return items
    }

    // MARK: Rendering

    private func setNeedsRedraw() { needsDisplay = true }

    /// Drops the cached base buffers; the next frame encodes them again.
    private func invalidateStatic() { staticBase = nil }

    override func draw(_ dirtyRect: NSRect) { render() }

    /// Cells (+ top rules, + ghosts) at their displayed rects. Returns the instance count.
    private func encodeBase(_ cp: UnsafeMutablePointer<CellInstance>) -> Int {
        guard let cells = layout?.cells else { return 0 }
        var nc = 0
        func put(_ r: CGRect, _ s: CellStyle, _ alpha: Float, rule: Bool) {
            if rule {
                // 2 pt rule along the top edge, inside the rim.
                let inset = CGFloat(s.borderWidth)
                let h = min(2, r.height - 2 * inset)
                guard h > 0, r.width > 2 * inset else { return }
                cp[nc] = CellInstance(
                    rect: SIMD4(Float(r.minX + inset), Float(r.minY + inset), Float(r.width - 2 * inset), Float(h)),
                    fill: SIMD4(s.header.x, s.header.y, s.header.z, s.header.w * alpha), border: .zero,
                    params: SIMD4(0, kCellModeNormal, 0, 1))
            } else {
                var b = s.border; b.w *= alpha
                cp[nc] = CellInstance(
                    rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                    fill: SIMD4(s.fill.x, s.fill.y, s.fill.z, alpha), border: b,
                    params: SIMD4(s.borderWidth, s.mode, s.bloom, s.radius))
            }
            nc += 1
        }
        for g in ghosts { put(g.rect, g.style, 1 - animProgress, rule: false) }
        for i in 0..<cells.count {
            let r = displayRects[i]
            if r.width < 0.4 || r.height < 0.4 { continue }
            put(r, styles[i], displayAlpha[i], rule: false)
            if styles[i].topRule { put(r, styles[i], displayAlpha[i], rule: true) }
        }
        return nc
    }

    /// Label bitmaps at their displayed cell rects. Returns the instance count.
    private func encodeLabels(_ lp: UnsafeMutablePointer<LabelInstance>, scale: Float) -> Int {
        var nl = 0
        let inv = 1 / scale
        for item in labelItems {
            let ci = Int(item.cell)
            guard ci < displayRects.count else { continue }
            let r = displayRects[ci]
            let alpha = displayAlpha[ci]
            if alpha <= 0.01 || r.width < 8 || r.height < 6 { continue }
            let w = Float(item.entry.size.width), h = Float(item.entry.size.height)
            var x: Float
            switch item.anchor {
            case .left: x = Float(r.minX) + item.dx
            case .center: x = Float(r.midX) - w / 2
            case .right: x = Float(r.maxX) - w - item.dx
            }
            var y = Float(r.minY) + item.dy
            x = (x * scale).rounded() * inv
            y = (y * scale).rounded() * inv
            var color = item.color
            color.w *= alpha * (item.dim ? 0.5 : 1)
            lp[nl] = LabelInstance(dst: SIMD4(x, y, w, h), uv: item.entry.pixels, color: color,
                                   clip: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)))
            nl += 1
        }
        return nl
    }

    /// Hover, selection and tray markers. Returns the instance count.
    private func encodeOverlays(_ cp: UnsafeMutablePointer<CellInstance>) -> Int {
        var nc = 0
        func overlay(_ id: NodeID, fill: SIMD4<Float>, border: SIMD4<Float>, width: Float, mode: Float) {
            guard let i = indexByID[id] else { return }
            let r = displayRects[i]
            guard r.width >= 1, r.height >= 1 else { return }
            cp[nc] = CellInstance(rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                  fill: fill, border: border, params: SIMD4(width, mode, 0, styles[i].radius))
            nc += 1
        }
        let tc = palette.trayColor
        for id in tray {
            // Light marker: 2 pt inset outline plus a corner badge; content and labels stay readable.
            overlay(id, fill: SIMD4(tc.x, tc.y, tc.z, 0), border: SIMD4(tc.x, tc.y, tc.z, 1), width: 2, mode: kCellModeOutline)
            if let i = indexByID[id] {
                let r = displayRects[i]
                if r.width >= 24, r.height >= 24 {
                    let size = Float(min(16, min(r.width, r.height) / 3))
                    cp[nc] = CellInstance(rect: SIMD4(Float(r.maxX) - size, Float(r.minY), size, size),
                                          fill: SIMD4(tc.x, tc.y, tc.z, 1), border: .zero,
                                          params: SIMD4(0, kCellModeBadge, 0, 0))
                    nc += 1
                }
            }
        }
        let ac = palette.accent
        for id in selected {
            overlay(id, fill: SIMD4(ac.x, ac.y, ac.z, 0.16), border: ac, width: 3, mode: kCellModeOutline)
        }
        if let h = hovered {
            overlay(h, fill: palette.hoverFill, border: palette.hoverColor, width: 2, mode: kCellModeOutline)
        }
        return nc
    }

    /// Base cells and labels of a frame: buffers plus instance counts.
    private struct BaseBuffers {
        var cells: MTLBuffer
        var cellCount: Int
        var labels: MTLBuffer
        var labelCount: Int
    }

    /// Encodes base cells and labels into `cells`/`labels` (grown when too small).
    private func encodeBaseBuffers(cells: inout MTLBuffer?, labels: inout MTLBuffer?, scale: Float,
                                   device: MTLDevice) -> BaseBuffers {
        let n = layout?.cells.count ?? 0
        let cellCap = max(ghosts.count + n * 2, 1)
        let cb = ensure(&cells, cellCap * MemoryLayout<CellInstance>.stride, device)
        let nc = encodeBase(cb.contents().bindMemory(to: CellInstance.self, capacity: cellCap))
        let labelCap = max(labelItems.count, 1)
        let lb = ensure(&labels, labelCap * MemoryLayout<LabelInstance>.stride, device)
        let nl = encodeLabels(lb.contents().bindMemory(to: LabelInstance.self, capacity: labelCap), scale: scale)
        return BaseBuffers(cells: cb, cellCount: nc, labels: lb, labelCount: nl)
    }

    private func render() {
        guard layout != nil, let device else { return }
        // Take a frame slot before the drawable: then the semaphore, not a blocking
        // nextDrawable, limits the frames in flight.
        inflight.wait()
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor else {
            inflight.signal()
            return
        }
        slot = (slot + 1) % 3
        pass.colorAttachments[0].clearColor = palette.background
        pass.colorAttachments[0].loadAction = .clear

        let scale = Float(window?.backingScaleFactor ?? 2)

        // Base cells and labels: while a tween runs they change every frame and go into the
        // per-frame slot buffers. Otherwise they are encoded once into fresh buffers and reused
        // until the layout, appearance or scale changes (frames still in flight keep the old ones).
        let base: BaseBuffers
        if anim != nil {
            base = encodeBaseBuffers(cells: &cellBuffers[slot], labels: &labelBuffers[slot], scale: scale, device: device)
        } else if let s = staticBase, staticScale == scale {
            base = s
        } else {
            var c: MTLBuffer?, l: MTLBuffer?
            base = encodeBaseBuffers(cells: &c, labels: &l, scale: scale, device: device)
            staticBase = base
            staticScale = scale
        }

        // Overlays: small, written every frame.
        let overlayCap = tray.count * 2 + selected.count + 1
        let ob = ensure(&overlayBuffers[slot], overlayCap * MemoryLayout<CellInstance>.stride, device)
        let no = encodeOverlays(ob.contents().bindMemory(to: CellInstance.self, capacity: overlayCap))

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return
        }
        var u = MapUniforms(viewSize: SIMD2(Float(bounds.width), Float(bounds.height)),
                            atlasSize: SIMD2(Float(LabelAtlas.width), Float(LabelAtlas.height)), scale: scale)
        enc.setVertexBytes(&u, length: MemoryLayout<MapUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<MapUniforms>.stride, index: 1)
        // Cells, then labels, then overlays on top.
        if base.cellCount > 0 {
            enc.setRenderPipelineState(cellPipeline)
            enc.setVertexBuffer(base.cells, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: base.cellCount)
        }
        if base.labelCount > 0 {
            enc.setRenderPipelineState(labelPipeline)
            enc.setVertexBuffer(base.labels, offset: 0, index: 0)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: base.labelCount)
        }
        if no > 0 {
            enc.setRenderPipelineState(cellPipeline)
            enc.setVertexBuffer(ob, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: no)
        }
        enc.endEncoding()
        cmd.present(drawable)
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.commit()
    }

    private func ensure(_ slot: inout MTLBuffer?, _ length: Int, _ device: MTLDevice) -> MTLBuffer {
        if let b = slot, b.length >= length { return b }
        let b = device.makeBuffer(length: max(length * 5 / 4, 4096), options: .storageModeShared)!
        slot = b
        return b
    }

    // MARK: Appearance / scale / size

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = MapPalette(appearance: effectiveAppearance)
        clearColor = palette.background
        if let cells = layout?.cells {
            let heat = HeatScale(cells: cells)
            styles = cells.map { palette.style(for: $0, heat: heat) }
        }
        if layout != nil { planLabels() }
        invalidateStatic()
        setNeedsRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let device, let s = window?.backingScaleFactor, s != atlas.scale else { return }
        atlas = LabelAtlas(device: device, scale: s)
        if layout != nil { planLabels() }
        invalidateStatic()
        setNeedsRedraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() }
        viewDidChangeBackingProperties()
        viewDidChangeEffectiveAppearance()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRedraw()
        onResize?(newSize)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func refreshHover() {
        guard mouseInside else { return }
        updateHover()
    }

    /// Hover rules in one place: the view root is highlighted but reported as nil, so the
    /// inspector falls back to the selection.
    private func updateHover() {
        let id = mouseInside ? node(at: lastMouse) : nil
        guard id != hovered else { return }
        hovered = id
        onHoverChange?(id == layout?.root ? nil : id)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        updateHover()
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouse = point(event)
        mouseInside = true
        updateHover()
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let id = node(at: point(event))
        if event.clickCount >= 2 {
            if let id { onDoubleClick?(id) }
        } else {
            onClick?(id, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let id = node(at: point(event)) else { return }
        onContextMenu?(id, event)
    }

    override func keyDown(with event: NSEvent) {
        // AppKit offers only modified keys to the main menu, so plain-key menu shortcuts
        // (Space, ⌫, ↩) arrive here. Give them to the menu first.
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        interpretKeyEvents([event])
    }

    // Standard key bindings: plain arrows, Esc and Enter arrive here. Other keys fall through
    // to NSResponder, which passes them up the chain (and beeps if nobody wants them).
    override func moveLeft(_ sender: Any?) { onKeyCommand?(.move(.left)) }
    override func moveRight(_ sender: Any?) { onKeyCommand?(.move(.right)) }
    override func moveUp(_ sender: Any?) { onKeyCommand?(.move(.up)) }
    override func moveDown(_ sender: Any?) { onKeyCommand?(.move(.down)) }
    override func cancelOperation(_ sender: Any?) { onKeyCommand?(.cancel) }
    override func insertNewline(_ sender: Any?) { onKeyCommand?(.enter) }
}
