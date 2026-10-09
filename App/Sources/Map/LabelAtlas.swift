import AppKit
import CoreText
import Metal

enum LabelStyle: UInt8 {
    case dirName, fileName, size, topDirName
}

/// A rasterised label inside the atlas texture.
struct AtlasEntry {
    /// x, y, w, h in atlas pixels.
    var pixels: SIMD4<Float>
    /// Size in view points (excluding nothing: the bitmap includes a 1 px pad each side).
    var size: CGSize
}

/// Packs Core Text label bitmaps (8-bit coverage masks) into one R8 texture with a shelf
/// packer. Entries are cached by text, style and quantised width, so a label is rasterised
/// once and then drawn as one textured quad per frame. Text color is applied in the shader,
/// so appearance changes never invalidate the cache. When the atlas fills up it is replaced
/// by a fresh texture and `epoch` increases; callers must re-resolve their entries.
@MainActor
final class LabelAtlas {
    static let width = 8192
    static let height = 4096

    private struct Key: Hashable {
        var text: String
        var style: UInt8
        var width: Int32 // 0: natural (untruncated) width
    }
    private struct NaturalKey: Hashable {
        var text: String
        var style: UInt8
    }

    let device: MTLDevice
    let scale: CGFloat
    private(set) var texture: MTLTexture
    private(set) var epoch = 0

    private var cache: [Key: AtlasEntry?] = [:]
    /// Shaped, untruncated line and its width in points; rasterising reuses the line.
    private var natural: [NaturalKey: (line: CTLine, width: CGFloat)] = [:]
    private var cursorX = 1, shelfY = 1, shelfH = 0
    private let fonts: [CTFont]
    private let ellipsis: [CTLine]

    init(device: MTLDevice, scale: CGFloat) {
        self.device = device
        self.scale = scale
        texture = Self.makeTexture(device)
        func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
            NSFont.systemFont(ofSize: size * scale, weight: weight) as CTFont
        }
        fonts = [font(11, .semibold), font(11.5, .semibold), font(10.5, .medium), font(12.5, .bold)]
        ellipsis = fonts.map { f in
            CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: Self.attrs(f)))
        }
    }

    private static func attrs(_ font: CTFont) -> [NSAttributedString.Key: Any] {
        [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    }

    private static func makeTexture(_ device: MTLDevice) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    /// Line height in points for a style.
    func lineHeight(_ style: LabelStyle) -> CGFloat {
        let f = fonts[Int(style.rawValue)]
        return ceil(CTFontGetAscent(f) + CTFontGetDescent(f)) / scale
    }

    /// Returns the label bitmap for `text` fitting `maxWidth` points, or nil if it does not fit.
    func entry(_ text: String, style: LabelStyle, maxWidth: CGFloat) -> AtlasEntry? {
        guard maxWidth >= 14, !text.isEmpty else { return nil }
        let nk = NaturalKey(text: text, style: style.rawValue)
        let nat: (line: CTLine, width: CGFloat)
        if let hit = natural[nk] {
            nat = hit
        } else {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: Self.attrs(fonts[Int(style.rawValue)])))
            nat = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / scale)
            natural[nk] = nat
        }
        let w: Int32
        if nat.width <= maxWidth {
            w = 0
        } else {
            // Quantise so live-resizing cells reuse bitmaps instead of re-rasterising.
            w = Int32(max(14, floor(maxWidth / 6) * 6))
        }
        let key = Key(text: text, style: style.rawValue, width: w)
        if let hit = cache[key] { return hit }
        let e = rasterise(nat.line, style: style, maxWidth: w == 0 ? nil : CGFloat(w))
        cache[key] = .some(e)
        return e
    }

    private func rasterise(_ full: CTLine, style: LabelStyle, maxWidth: CGFloat?) -> AtlasEntry? {
        let font = fonts[Int(style.rawValue)]
        var line = full
        if let maxWidth {
            guard let t = CTLineCreateTruncatedLine(line, Double(maxWidth * scale), .end, ellipsis[Int(style.rawValue)]) else { return nil }
            line = t
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let textW = CTLineGetTypographicBounds(line, nil, nil, nil)
        let pw = Int(ceil(textW)) + 2
        let ph = Int(ceil(ascent + descent)) + 2
        guard let (x, y) = allocate(pw, ph) else { return nil }

        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Gray context: draw white on black; the red channel is the coverage mask.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.textPosition = CGPoint(x: 1, y: 1 + descent)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }
        texture.replace(region: MTLRegionMake2D(x, y, pw, ph), mipmapLevel: 0, withBytes: data, bytesPerRow: pw)
        return AtlasEntry(pixels: SIMD4(Float(x), Float(y), Float(pw), Float(ph)),
                          size: CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale))
    }

    private func allocate(_ w: Int, _ h: Int) -> (Int, Int)? {
        if w > Self.width - 2 || h > 256 { return nil }
        if cursorX + w + 1 > Self.width {
            cursorX = 1; shelfY += shelfH + 1; shelfH = 0
        }
        if shelfY + h + 1 > Self.height {
            reset()
            return allocate(w, h)
        }
        let p = (cursorX, shelfY)
        cursorX += w + 1
        shelfH = max(shelfH, h)
        return p
    }

    private func reset() {
        texture = Self.makeTexture(device)
        cache.removeAll(keepingCapacity: true)
        natural.removeAll(keepingCapacity: true)
        cursorX = 1; shelfY = 1; shelfH = 0
        epoch += 1
    }
}
