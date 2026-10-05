import SwiftUI

/// Hosts the model's Metal map view in SwiftUI.
struct MapHost: NSViewRepresentable {
    let model: ScanModel

    func makeNSView(context: Context) -> TreemapMapView {
        model.configureMap()
        return model.map
    }

    func updateNSView(_ nsView: TreemapMapView, context: Context) {}
}

/// Gives SwiftUI content access to its NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window, let cb = onWindow { DispatchQueue.main.async { cb(w) } }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.onWindow = onWindow
        return p
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}
