// Draws the app icon (a squarified treemap, laid out by TreemapCore's TreemapLayouter) with
// Core Graphics and writes an AppIcon.appiconset with every macOS size.
//
//   swift run make-icon App/Resources/Assets.xcassets/AppIcon.appiconset   (or `make icon`)
//
// The artwork is full-bleed and square; macOS 26 applies the rounded-rect mask itself.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import TreemapCore
import UniformTypeIdentifiers

/// One root directory with a file per tile. Node 0 is the root, tile `n` is node `n + 1`.
struct IconTree: LayoutTree {
    let values: [Int64]
    func name(of id: NodeID) -> String { "t\(id.raw)" }
    func size(of id: NodeID) -> Int64 { id.raw == 0 ? values.reduce(0, +) : values[Int(id.raw) - 1] }
    func flags(of id: NodeID) -> CellFlags { id.raw == 0 ? .directory : [] }
    func children(of id: NodeID) -> [NodeID] {
        id.raw == 0 ? (1...values.count).map { NodeID(raw: UInt32($0)) } : []
    }
}

func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
    NSColor(hue: h - floor(h), saturation: s, brightness: b, alpha: 1).cgColor
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixels) / 1024
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)   // top-left origin
    ctx.interpolationQuality = .high

    // Background: deep blue-violet vertical gradient, full bleed.
    let bg = CGGradient(colorsSpace: space, colors: [hsb(0.66, 0.60, 0.20), hsb(0.70, 0.62, 0.09)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])

    // Treemap in the safe area (150 pt inset). The layouter's padding is the gap between tiles:
    // it tessellates the bounds shrunk by half a gap and insets every tile by half a gap.
    let inset: CGFloat = 150
    let gap: CGFloat = 12
    let values: [Int64] = [3800, 2400, 1700, 1200, 900, 600, 500, 350]
    let hues: [CGFloat] = [0.53, 0.60, 0.74, 0.08, 0.47, 0.82, 0.58, 0.12]
    var options = LayoutOptions()
    options.padding = gap
    options.minCellArea = 1
    let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024).insetBy(dx: inset - gap / 2, dy: inset - gap / 2)
    let layout = TreemapLayouter.layout(tree: IconTree(values: values), root: NodeID(raw: 0), bounds: bounds, options: options)
    for cell in layout.cells.dropFirst() {
        guard let id = cell.node else { continue }
        let hue = hues[Int(id.raw) - 1]
        let r = cell.rect
        let radius: CGFloat = min(34, min(r.width, r.height) / 4)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Soft shadow under each tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(hsb(hue, 0.70, 0.80))
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        // Gradient fill, lighter at the top.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: space,
                           colors: [hsb(hue, 0.55, 0.98), hsb(hue + 0.02, 0.78, 0.74)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        ctx.restoreGState()
        // Fine inner highlight.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

// MARK: Main

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    write(render(pixels: px), to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(outDir.path)")
