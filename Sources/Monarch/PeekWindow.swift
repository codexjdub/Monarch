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
    private struct WindowEntry {
        let window: PeekNSWindow
        let hostingController: NSHostingController<AnyView>
    }

    private enum HorizontalDirection {
        case left
        case right
    }

    enum WidthPolicy {
        case fixed
        case flexible(minWidth: CGFloat)
    }

    private struct PlacementCandidate {
        let direction: HorizontalDirection
        let frame: NSRect
        let clampDistance: CGFloat
        let overlapArea: CGFloat
        let gapShortfall: CGFloat
        let widthCompression: CGFloat
    }

    let defaultSize = NSSize(width: 320, height: 440)
    let minimumFolderWidth: CGFloat = 240
    private let preferredGap: CGFloat = 6
    private let minimumGap: CGFloat = 2
    private let edgePadding: CGFloat = 8
    private let sideSwitchHysteresis: CGFloat = 18
    private let peekAnimationDuration: TimeInterval = 0.20
    private var windows: [Int: WindowEntry] = [:]
    private var directions: [Int: HorizontalDirection] = [:]

    // MARK: Window lifecycle

    func present(atLevel level: Int,
                 anchor: NSRect,
                 size: NSSize,
                 widthPolicy: WidthPolicy = .fixed,
                 content: AnyView) {
        guard let screen = screen(for: anchor) else { return }

        let fittedSize = fittedSize(for: size, on: screen)
        let placement = bestPlacement(atLevel: level,
                                      anchor: anchor,
                                      size: fittedSize,
                                      widthPolicy: widthPolicy,
                                      on: screen)
        let finalFrame = placement.frame
        let appearance = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? ""
        )?.nsAppearance

        if let existing = windows[level] {
            existing.hostingController.rootView = content
            existing.window.appearance = appearance
            animateReplacement(of: existing.window, to: finalFrame)
            directions[level] = placement.direction
            return
        }

        let win = PeekNSWindow(
            contentRect: finalFrame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .popUpMenu
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.transient, .ignoresCycle]
        win.appearance = appearance

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
        let startFrame = NSRect(x: finalFrame.origin.x,
                                y: finalFrame.origin.y - 6,
                                width: finalFrame.size.width,
                                height: finalFrame.size.height)
        animateInitialPresentation(of: win, from: startFrame, to: finalFrame)
        windows[level] = WindowEntry(window: win, hostingController: hc)
        directions[level] = placement.direction
    }

    func close(level: Int) {
        windows[level]?.window.close()
        windows[level] = nil
        directions[level] = nil
    }

    func hasWindow(atLevel level: Int) -> Bool {
        windows[level] != nil
    }

    /// All level keys strictly above `minLevel`, unsorted.
    func levels(greaterThan minLevel: Int) -> [Int] {
        windows.keys.filter { $0 > minLevel }
    }

    private func screen(for anchor: NSRect) -> NSScreen? {
        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func fittedSize(for proposedSize: NSSize, on screen: NSScreen) -> NSSize {
        let visible = screen.visibleFrame.insetBy(dx: edgePadding, dy: edgePadding)
        return NSSize(
            width: min(proposedSize.width, visible.width),
            height: min(proposedSize.height, visible.height)
        )
    }

    private func bestPlacement(atLevel level: Int,
                               anchor: NSRect,
                               size: NSSize,
                               widthPolicy: WidthPolicy,
                               on screen: NSScreen) -> PlacementCandidate {
        let preferredDirection = directions[level] ?? directions[level - 1]
        let leftCandidate = candidate(for: .left,
                                      atLevel: level,
                                      anchor: anchor,
                                      size: size,
                                      widthPolicy: widthPolicy,
                                      on: screen)
        let rightCandidate = candidate(for: .right,
                                       atLevel: level,
                                       anchor: anchor,
                                       size: size,
                                       widthPolicy: widthPolicy,
                                       on: screen)

        if let preferredDirection {
            let preferredCandidate = preferredDirection == .left ? leftCandidate : rightCandidate
            let alternateCandidate = preferredDirection == .left ? rightCandidate : leftCandidate
            let preferredScore = score(preferredCandidate)
            let alternateScore = score(alternateCandidate)
            if alternateScore + sideSwitchHysteresis < preferredScore {
                return alternateCandidate
            }
            return preferredCandidate
        }

        let leftScore = score(leftCandidate)
        let rightScore = score(rightCandidate)
        if leftScore == rightScore {
            return rightCandidate
        }
        return leftScore < rightScore ? leftCandidate : rightCandidate
    }

    private func candidate(for direction: HorizontalDirection,
                           atLevel level: Int,
                           anchor: NSRect,
                           size: NSSize,
                           widthPolicy: WidthPolicy,
                           on screen: NSScreen) -> PlacementCandidate {
        let visible = screen.visibleFrame.insetBy(dx: edgePadding, dy: edgePadding)
        let totalAvailable: CGFloat
        let shortfall: CGFloat
        let gap: CGFloat

        switch direction {
        case .right:
            totalAvailable = visible.maxX - anchor.maxX
        case .left:
            totalAvailable = anchor.minX - visible.minX
        }

        shortfall = max(0, preferredGap - totalAvailable)
        gap = max(minimumGap, preferredGap - shortfall)
        let width = width(for: size.width,
                          totalAvailable: totalAvailable,
                          gap: gap,
                          policy: widthPolicy,
                          visibleWidth: visible.width)
        let minX = visible.minX
        let maxX = max(minX, visible.maxX - width)
        let idealX: CGFloat
        switch direction {
        case .right:
            idealX = anchor.maxX + gap
        case .left:
            idealX = anchor.minX - width - gap
        }

        let originX = min(max(idealX, minX), maxX)
        let maxY = max(visible.minY, visible.maxY - size.height)
        let originY = min(max(anchor.maxY - size.height, visible.minY), maxY)
        let frame = NSRect(x: originX, y: originY, width: width, height: size.height)
        return PlacementCandidate(
            direction: direction,
            frame: frame,
            clampDistance: abs(originX - idealX),
            overlapArea: overlappingArea(for: frame, excluding: level),
            gapShortfall: shortfall,
            widthCompression: max(0, size.width - width)
        )
    }

    private func width(for proposedWidth: CGFloat,
                       totalAvailable: CGFloat,
                       gap: CGFloat,
                       policy: WidthPolicy,
                       visibleWidth: CGFloat) -> CGFloat {
        switch policy {
        case .fixed:
            return min(proposedWidth, visibleWidth)
        case .flexible(let minWidth):
            let boundedMinimum = min(minWidth, visibleWidth)
            let usableWidth = max(0, totalAvailable - gap)
            let targetWidth = min(proposedWidth, max(boundedMinimum, usableWidth))
            return min(targetWidth, visibleWidth)
        }
    }

    private func score(_ candidate: PlacementCandidate) -> CGFloat {
        var total = candidate.clampDistance * 3
        total += candidate.gapShortfall * 8
        total += candidate.overlapArea / 80
        total += candidate.widthCompression * 0.25
        return total
    }

    private func overlappingArea(for frame: NSRect, excluding level: Int) -> CGFloat {
        windows
            .filter { $0.key != level }
            .reduce(0) { partial, element in
                let intersection = frame.intersection(element.value.window.frame)
                guard !intersection.isNull else { return partial }
                return partial + (intersection.width * intersection.height)
            }
    }

    private func animateInitialPresentation(of window: PeekNSWindow, from startFrame: NSRect, to finalFrame: NSRect) {
        window.setFrame(startFrame, display: false)
        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = peekAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    private func animateReplacement(of window: PeekNSWindow, to finalFrame: NSRect) {
        window.orderFront(nil)
        if window.frame.equalTo(finalFrame) {
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = peekAnimationDuration * 0.9
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(finalFrame, display: true)
        }
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
            return NSSize(width: 520, height: 600)
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
