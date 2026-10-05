import AppKit
import QuickLookUI

/// Drives the shared QLPreviewPanel with the selected paths. The panel is wired directly
/// (not through the responder chain) so the map view needs no QuickLook knowledge.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    private var panel: QLPreviewPanel? { QLPreviewPanel.shared() }

    var isVisible: Bool { panel?.isVisible == true && panel?.dataSource === self }

    func toggle(_ urls: [URL]) {
        guard let panel else { return }
        if isVisible { panel.orderOut(nil); return }
        guard !urls.isEmpty else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func update(_ urls: [URL]) {
        guard isVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        panel?.reloadData()
    }

    func close() { if isVisible { panel?.orderOut(nil) } }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        index < urls.count ? urls[index] as NSURL : nil
    }
}
