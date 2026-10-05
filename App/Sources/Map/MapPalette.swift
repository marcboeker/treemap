import AppKit
import TreemapCore
import simd

/// Per-cell draw style, computed once per layout and appearance.
struct CellStyle {
    var fill: SIMD4<Float>
    var header: SIMD4<Float>
    var border: SIMD4<Float>
    var borderWidth: Float
    var mode: Float
    var hasHeader: Bool
    var dimLabel: Bool
}

/// Colors for one appearance. Flat fills, hue from the depth-1 subtree, lightness by depth.
struct MapPalette {
    let dark: Bool
    let accent: SIMD4<Float>

    var background: MTLClearColor {
        dark ? MTLClearColor(red: 0.075, green: 0.075, blue: 0.085, alpha: 1)
             : MTLClearColor(red: 0.90, green: 0.90, blue: 0.91, alpha: 1)
    }
    var textPrimary: SIMD4<Float> { dark ? [0.95, 0.95, 0.96, 0.95] : [0.08, 0.08, 0.09, 0.92] }
    var textSecondary: SIMD4<Float> { dark ? [0.95, 0.95, 0.96, 0.62] : [0.08, 0.08, 0.09, 0.62] }
    var hoverColor: SIMD4<Float> { dark ? [1, 1, 1, 0.95] : [0, 0, 0, 0.85] }
    var hoverFill: SIMD4<Float> { dark ? [1, 1, 1, 0.10] : [0, 0, 0, 0.07] }
    /// systemOrange in this appearance.
    let trayColor: SIMD4<Float>

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

    func style(for cell: TreemapCell) -> CellStyle {
        let f = cell.flags
        let depth = Float(min(Int(cell.depth), 6))
        let isDir = f.contains(.directory)
        let ink: SIMD4<Float> = dark ? [0, 0, 0, 0.55] : [0.07, 0.07, 0.08, 0.5]
        var bw: Float = isDir ? max(0.75, 1.1 - depth * 0.08) : 0.5
        var mode = kCellModeNormal
        var fill: SIMD4<Float>
        var header: SIMD4<Float>
        var border = ink

        if cell.parent < 0 {
            fill = dark ? [0.11, 0.11, 0.125, 1] : [0.95, 0.95, 0.96, 1]
            header = dark ? [0.17, 0.17, 0.19, 1] : [0.99, 0.99, 1.0, 1]
            bw = 0
        } else if f.contains(.mountPoint) {
            fill = dark ? Self.hsl(0, 0, 0.30) : Self.hsl(0, 0, 0.66)
            header = Self.lighten(fill, dark ? 0.07 : 0.06)
        } else if f.contains(.aggregate) {
            fill = dark ? Self.hsl(0, 0, 0.20) : Self.hsl(0, 0, 0.80)
            header = fill
            border = dark ? [0.7, 0.7, 0.75, 0.55] : [0.25, 0.25, 0.3, 0.55]
            mode = kCellModeAggregate
            bw = 0.5
        } else {
            let hue = cell.hue
            if isDir {
                let l: Float = dark ? 0.15 + 0.022 * depth : 0.72 + 0.024 * depth
                fill = Self.hsl(hue, dark ? 0.42 : 0.52, l)
            } else {
                fill = Self.hsl(hue, dark ? 0.34 : 0.42, dark ? 0.36 : 0.93)
            }
            header = Self.lighten(fill, dark ? 0.085 : 0.075)
            if f.contains(.scanning) {
                // Paler: less saturated, pulled toward the background.
                let bg: SIMD4<Float> = dark ? [0.17, 0.17, 0.19, 1] : [0.93, 0.93, 0.94, 1]
                fill = simd_mix(fill, bg, SIMD4(repeating: 0.5))
                header = simd_mix(header, bg, SIMD4(repeating: 0.4))
            }
            if f.contains(.unreadable) {
                fill = simd_mix(fill, dark ? [0.2, 0.2, 0.2, 1] : [0.8, 0.8, 0.8, 1], SIMD4(repeating: 0.55))
                header = fill
                border = dark ? [0.85, 0.85, 0.85, 0.9] : [0.1, 0.1, 0.1, 0.8]
                mode = kCellModeHatch
            }
        }
        fill.w = 1; header.w = 1
        let isHeader = isDir && f.contains(.hasHeader)
        return CellStyle(fill: fill, header: header, border: border, borderWidth: bw, mode: mode,
                         hasHeader: isHeader, dimLabel: f.contains(.hidden))
    }

    private static func lighten(_ c: SIMD4<Float>, _ d: Float) -> SIMD4<Float> {
        SIMD4(min(c.x + d, 1), min(c.y + d, 1), min(c.z + d, 1), 1)
    }
}
