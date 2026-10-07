import AppKit
import TreemapCore
import simd

/// Per-cell draw style, computed once per layout and appearance.
struct CellStyle {
    var fill: SIMD4<Float>
    /// Top rule color (depth-1 directories).
    var header: SIMD4<Float>
    var border: SIMD4<Float>
    var borderWidth: Float
    var mode: Float
    var radius: Float
    /// 0...1: white glow from the center (the largest files in dark mode).
    var bloom: Float
    var hasHeader: Bool
    var topRule: Bool
    var dimLabel: Bool
    /// Name label color, and size label color.
    var text: SIMD4<Float>
    var subtext: SIMD4<Float>
}

/// Log scale over the file sizes of one layout: 0 for the smallest file, 1 for the largest.
struct HeatScale {
    private var lo: Float = 0
    private var span: Float = 0

    init(cells: [TreemapCell]) {
        var mn = Int64.max, mx: Int64 = 0
        for c in cells where c.size > 0 && !c.flags.contains(.directory) && !c.flags.contains(.aggregate) {
            mn = min(mn, c.size); mx = max(mx, c.size)
        }
        guard mx > 0 else { return }
        lo = log(Float(mn))
        span = log(Float(mx)) - lo
    }

    func t(_ size: Int64) -> Float {
        guard size > 0 else { return 0 }
        guard span > 0 else { return 1 }
        return simd_clamp((log(Float(size)) - lo) / span, 0, 1)
    }
}

/// Colors for one appearance. Directories are dark wells (light trays in light mode) with a rim
/// in the hue of their depth-1 subtree; files get brighter (dark) or denser (light) with size.
struct MapPalette {
    let dark: Bool
    let accent: SIMD4<Float>

    var background: MTLClearColor {
        dark ? MTLClearColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1)
             : MTLClearColor(red: 0.894, green: 0.894, blue: 0.906, alpha: 1)
    }
    var hoverColor: SIMD4<Float> { dark ? [1, 1, 1, 0.95] : [0, 0, 0, 0.85] }
    var hoverFill: SIMD4<Float> { dark ? [1, 1, 1, 0.10] : [0, 0, 0, 0.07] }
    /// systemOrange in this appearance.
    let trayColor: SIMD4<Float>

    private var lightInk: (SIMD4<Float>, SIMD4<Float>) { ([0.98, 0.98, 0.99, 0.95], [0.98, 0.98, 0.99, 0.68]) }
    private var darkInk: (SIMD4<Float>, SIMD4<Float>) { ([0.04, 0.04, 0.055, 0.92], [0.04, 0.04, 0.055, 0.64]) }

    @MainActor
    init(appearance: NSAppearance) {
        dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        accent = Self.srgb(.controlAccentColor, in: appearance, fallback: [0.04, 0.52, 1.0, 1])
        trayColor = Self.srgb(.systemOrange, in: appearance, fallback: [1.0, 0.62, 0.04, 1])
    }

    /// A dynamic system color resolved for `appearance`, as opaque sRGB.
    @MainActor
    private static func srgb(_ color: NSColor, in appearance: NSAppearance, fallback: SIMD4<Float>) -> SIMD4<Float> {
        var rgb = fallback
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                rgb = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
            }
        }
        return rgb
    }

    static func hsl(_ h: Float, _ s: Float, _ l: Float, _ a: Float = 1) -> SIMD4<Float> {
        let hh = (h - floor(h)) * 6
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Float, Float, Float)
        switch Int(hh) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return SIMD4(r + m, g + m, b + m, a)
    }

    /// Relative luminance of an sRGB color.
    private static func luminance(_ c: SIMD4<Float>) -> Float {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
    }

    /// Label colors that read on `fill`.
    private func ink(on fill: SIMD4<Float>) -> (SIMD4<Float>, SIMD4<Float>) {
        Self.luminance(fill) > 0.18 ? darkInk : lightInk
    }

    /// File fill for heat `t`: dark tint → full hue → pale (dark), or pale tint → deep hue (light).
    private func fileFill(hue: Float, t: Float) -> SIMD4<Float> {
        if t < 0.55 {
            let u = t / 0.55
            return dark ? Self.hsl(hue, 0.32 + 0.43 * u, 0.14 + 0.22 * u)
                        : Self.hsl(hue, 0.35 + 0.30 * u, 0.88 - 0.16 * u)
        }
        let u = (t - 0.55) / 0.45
        return dark ? Self.hsl(hue, 0.75 - 0.15 * u, 0.36 + 0.46 * u)
                    : Self.hsl(hue, 0.65 + 0.10 * u, 0.72 - 0.34 * u)
    }

    func style(for cell: TreemapCell, heat: HeatScale) -> CellStyle {
        let f = cell.flags
        let depth = Int(min(cell.depth, 12))
        let hue = cell.hue
        let isDir = f.contains(.directory)
        let bg = SIMD4(Float(background.red), Float(background.green), Float(background.blue), 1)
        let neutral: SIMD4<Float> = dark ? [0.7, 0.7, 0.75, 0.55] : [0.25, 0.25, 0.3, 0.55]
        var s = CellStyle(fill: bg, header: .zero, border: .zero, borderWidth: 0, mode: kCellModeNormal,
                          radius: isDir ? 3 : 2, bloom: 0, hasHeader: isDir && f.contains(.hasHeader),
                          topRule: false, dimLabel: f.contains(.hidden), text: lightInk.0, subtext: lightInk.1)

        if cell.parent < 0 {
            s.radius = 0
        } else if f.contains(.aggregate) {
            s.fill = dark ? Self.hsl(0, 0, 0.17) : Self.hsl(0, 0, 0.82)
            s.border = neutral
            s.borderWidth = 0.5
            s.mode = kCellModeAggregate
        } else if f.contains(.mountPoint) {
            s.fill = dark ? Self.hsl(0, 0, 0.26) : Self.hsl(0, 0, 0.72)
            s.border = neutral
            s.borderWidth = 1
        } else if isDir {
            // Wells: every level a little darker than the one above it.
            s.fill = dark ? SIMD4(0.067, 0.067, 0.078, 1) * pow(0.7, Float(depth - 1))
                          : SIMD4(0.965, 0.965, 0.973, 1) * pow(0.965, Float(depth - 1))
            s.border = dark ? Self.hsl(hue, 0.85, 0.62, depth == 1 ? 0.7 : 0.28)
                            : Self.hsl(hue, 0.60, 0.45, depth == 1 ? 0.5 : 0.22)
            s.borderWidth = 1
            if depth == 1 {
                s.topRule = true
                s.header = dark ? Self.hsl(hue, 0.95, 0.60) : Self.hsl(hue, 0.80, 0.45)
            }
            s.text = dark ? [0.96, 0.96, 0.965, depth == 1 ? 1 : 0.78] : [0.055, 0.055, 0.07, depth == 1 ? 0.92 : 0.7]
            s.subtext = dark ? Self.hsl(hue, 0.90, 0.70) : Self.hsl(hue, 0.70, 0.32)
            s.fill.w = 1
        } else {
            let t = heat.t(cell.size)
            s.fill = fileFill(hue: hue, t: t)
            s.bloom = dark && t > 0.7 ? 0.22 : 0
        }

        if f.contains(.scanning) {
            // Not fully walked yet: paler, rim fades.
            let toward: SIMD4<Float> = dark ? [0.17, 0.17, 0.19, 1] : [0.90, 0.90, 0.92, 1]
            s.fill = simd_mix(s.fill, toward, SIMD4(repeating: 0.4))
            s.border.w *= 0.45
            s.header.w *= 0.45
        }
        if f.contains(.unreadable) {
            s.fill = simd_mix(s.fill, dark ? [0.2, 0.2, 0.2, 1] : [0.8, 0.8, 0.8, 1], SIMD4(repeating: 0.55))
            s.border = dark ? [0.85, 0.85, 0.85, 0.9] : [0.1, 0.1, 0.1, 0.8]
            s.borderWidth = 1
            s.mode = kCellModeHatch
            s.bloom = 0
        }
        // Wells keep their header colors; every other label sits on its own fill.
        let well = isDir && cell.parent >= 0 && !f.contains(.mountPoint) && !f.contains(.unreadable)
        if !well { (s.text, s.subtext) = ink(on: s.fill) }
        s.fill.w = 1
        return s
    }
}
