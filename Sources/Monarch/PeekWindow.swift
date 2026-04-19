import AppKit
import SwiftUI
import ImageIO
import CoreGraphics

// MARK: - Peek window subclass

final class PeekNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Peek Window Manager
//
// Owns the window registry and all AppKit window-creation/animation logic.
// CascadeModel calls through here; it retains ownership of level state,
// watchers, focus, and search state.

@MainActor
final class PeekWindowManager {

    let defaultSize = NSSize(width: 320, height: 440)
    private let peekAnimationDuration: TimeInterval = 0.20
    private var windows: [Int: PeekNSWindow] = [:]

    // MARK: Window lifecycle

    func present(atLevel level: Int, anchor: NSRect, size: NSSize, content: AnyView) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
                        ?? NSScreen.main
                        ?? NSScreen.screens.first else { return }

        var origin = NSPoint(x: anchor.maxX + 2, y: anchor.maxY - size.height)
        if origin.x + size.width > screen.visibleFrame.maxX {
            origin.x = anchor.minX - size.width - 2
        }
        if origin.y < screen.visibleFrame.minY + 8 {
            origin.y = screen.visibleFrame.minY + 8
        }
        if origin.y + size.height > screen.visibleFrame.maxY {
            origin.y = screen.visibleFrame.maxY - size.height
        }

        let win = PeekNSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .popUpMenu
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.transient, .ignoresCycle]
        win.appearance = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? ""
        )?.nsAppearance

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.cgColor

        let hc = NSHostingController(rootView: content)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.clear.cgColor
        visualEffect.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])
        win.contentView = visualEffect

        // Animate in: slide up 6pt + fade from 0 → 1 over 120ms.
        let finalFrame = NSRect(origin: origin, size: size)
        let startFrame = NSRect(x: origin.x, y: origin.y - 6,
                                width: size.width, height: size.height)
        win.setFrame(startFrame, display: false)
        win.alphaValue = 0
        win.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = peekAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
            win.animator().setFrame(finalFrame, display: true)
        }
        windows[level] = win
    }

    func close(level: Int) {
        windows[level]?.close()
        windows[level] = nil
    }

    /// All level keys strictly above `minLevel`, unsorted.
    func levels(greaterThan minLevel: Int) -> [Int] {
        windows.keys.filter { $0 > minLevel }
    }

    // MARK: Preview sizing

    /// Compute a sensible window size for a file preview based on its content.
    static func previewSize(for url: URL, kind: PreviewKind) -> NSSize {
        let minW: CGFloat = 280, maxW: CGFloat = 800
        let minH: CGFloat = 200, maxH: CGFloat = 700
        let chromeH: CGFloat = 34  // header bar height

        switch kind {
        case .image:
            // Header-only read via ImageIO. Does not decode pixels — ~1ms for
            // any reasonable image, vs. hundreds of ms for NSImage(contentsOf:)
            // which fully decodes. Huge win on big JPEGs and RAW photos.
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth]  as? CGFloat,
               let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
               w > 0, h > 0 {
                let size = fit(aspect: NSSize(width: w, height: h),
                               minW: minW, maxW: maxW, minH: minH, maxH: maxH - chromeH)
                return NSSize(width: size.width, height: size.height + chromeH)
            }
            return NSSize(width: 520, height: 400)
        case .pdf:
            // CGPDFDocument is lighter than PDFKit's PDFDocument — it doesn't
            // parse content streams, just the catalog. Reading page 1's media
            // box is typically single-digit ms even for large files.
            if let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
                let bounds = page.getBoxRect(.mediaBox)
                if bounds.width > 0, bounds.height > 0 {
                    let size = fit(aspect: bounds.size,
                                   minW: minW, maxW: maxW, minH: minH, maxH: maxH - chromeH)
                    return NSSize(width: size.width, height: size.height + chromeH)
                }
            }
            return NSSize(width: 520, height: 600)
        case .markdown, .text:
            return NSSize(width: 520, height: 600)
        case .quicklook:
            return NSSize(width: 640, height: 780)
        case .video:
            return NSSize(width: 720, height: 480)
        case .audio:
            return NSSize(width: 480, height: 140)
        case .archive:
            return NSSize(width: 400, height: 500)
        }
    }

    private static func fit(aspect: NSSize, minW: CGFloat, maxW: CGFloat,
                             minH: CGFloat, maxH: CGFloat) -> NSSize {
        let ratio = aspect.width / aspect.height
        var w = maxW; var h = w / ratio
        if h > maxH { h = maxH; w = h * ratio }
        if w < minW { w = minW; h = w / ratio }
        if h < minH { h = minH; w = h * ratio }
        return NSSize(width: min(max(w, minW), maxW), height: min(max(h, minH), maxH))
    }
}
