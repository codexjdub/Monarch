import Cocoa
import QuickLookUI

@MainActor
final class QuickLookManager: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookManager()
    private var previewURLs: [URL] = []

    func show(urls: [URL]) {
        previewURLs = urls.filter { !$0.hasDirectoryPath }
        guard !previewURLs.isEmpty,
              let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }
}
