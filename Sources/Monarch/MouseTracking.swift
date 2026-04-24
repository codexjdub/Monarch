import AppKit
import SwiftUI

// MARK: - Row Frame Reporter
//
// Attached to each row; reports the row's screen frame to the model so that
// the window mouse tracker (and keyboard drill-in) can position peeks and
// hit-test the cursor against rows. Stateless — just geometry.

struct RowFrameReporter: NSViewRepresentable {
    let level: Int
    let index: Int
    let model: CascadeModel

    func makeNSView(context: Context) -> RowFrameReporterNSView {
        let v = RowFrameReporterNSView()
        v.configure(level: level, index: index, model: model)
        return v
    }
    func updateNSView(_ nsView: RowFrameReporterNSView, context: Context) {
        nsView.configure(level: level, index: index, model: model)
        nsView.reportIfReady()
    }
}

final class RowFrameReporterNSView: NSView {
    private var level: Int = 0
    private var index: Int = 0
    private weak var model: CascadeModel?
    private weak var observedClip: NSClipView?

    func configure(level: Int, index: Int, model: CascadeModel) {
        self.level = level
        self.index = index
        self.model = model
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // View is leaving its window — remove all observers immediately,
            // even if observedClip's weak ref has already gone nil.
            NotificationCenter.default.removeObserver(self)
            observedClip = nil
        }
        attachScrollObserverIfNeeded()
        reportIfReady()
    }
    override func layout() { super.layout(); reportIfReady() }
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize); reportIfReady()
    }

    /// Find the enclosing NSClipView (inside NSScrollView) and listen for
    /// bounds-changed notifications so the reported row frame stays fresh
    /// as the list scrolls.
    private func attachScrollObserverIfNeeded() {
        // Tear down any previous observer (in case we moved window).
        if let clip = observedClip {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: clip
            )
            observedClip = nil
        }
        guard window != nil else { return }

        var v: NSView? = self.superview
        while let s = v {
            if let clip = s as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(scrollDidChange),
                    name: NSView.boundsDidChangeNotification,
                    object: clip
                )
                observedClip = clip
                return
            }
            v = s.superview
        }
    }

    @objc private func scrollDidChange() { reportIfReady() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func reportIfReady() {
        guard let window, window.isVisible else { return }
        let inWin = convert(bounds, to: nil)
        let inScreen = window.convertToScreen(inWin)
        model?.setRowFrame(level: level, index: index, frame: inScreen)
    }
}

// MARK: - Window Mouse Tracker
//
// ONE tracker per window (popover or peek). On every mouse-move it asks the
// model "which row is the cursor on?" and reports hover events.
//
// Crucially: exits are driven ONLY by real `mouseExited` events. This view
// never synthesizes exits from polling — that's what caused the previous
// attempts to cascade-close the cascade during layout churn.

struct WindowMouseTracker: NSViewRepresentable {
    let level: Int
    let model: CascadeModel

    func makeNSView(context: Context) -> WindowMouseTrackerNSView {
        let v = WindowMouseTrackerNSView()
        v.configure(level: level, model: model)
        return v
    }
    func updateNSView(_ nsView: WindowMouseTrackerNSView, context: Context) {
        nsView.configure(level: level, model: model)
    }
}

final class WindowMouseTrackerNSView: NSView {
    private var level: Int = 0
    private weak var model: CascadeModel?
    private var area: NSTrackingArea?

    func configure(level: Int, model: CascadeModel) {
        self.level = level
        self.model = model
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(a)
        area = a
        // Prime: if the cursor is already inside (window just appeared under
        // the cursor), emulate an entry event — additive only.
        syncIfInside()
    }

    override func mouseEntered(with event: NSEvent) {
        model?.mouseEnteredWindow(level: level)
        syncWindowPresence(at: event.locationInWindow)
    }
    override func mouseMoved(with event: NSEvent) { syncWindowPresence(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        model?.mouseLeftWindow(level: level)
    }

    /// If the cursor is currently inside our bounds, mark the window as active.
    /// Row-level tracking handles the actual hovered row.
    private func syncIfInside() {
        guard let window, window.isVisible else { return }
        syncWindowPresence(at: window.mouseLocationOutsideOfEventStream, window: window)
    }

    private func syncWindowPresence(at mouseInWin: NSPoint) {
        guard let window, window.isVisible else { return }
        syncWindowPresence(at: mouseInWin, window: window)
    }

    private func syncWindowPresence(at mouseInWin: NSPoint, window: NSWindow) {
        let localPoint = convert(mouseInWin, from: nil)
        guard bounds.contains(localPoint) else { return }
        model?.mouseEnteredWindow(level: level)
    }
}
