import AppKit
import QuickShotCore

/// Owns the OCR review panel. SHELL wires `onCopy` / `onDismiss` to
/// `workflow.dispatch(.ocrReviewCopy)` / `.ocrReviewDismiss` and maps
/// `showOCRReview` / `hideOCRReview` effects onto `show` / `hide`.
@MainActor
public final class OCRReviewCoordinator {
    public var onCopy: (() -> Void)?
    public var onDismiss: (() -> Void)?

    private var panel: OCRReviewPanel?
    private var reviewView: OCRReviewView?

    private static let panelSize = NSSize(width: 392, height: 248)

    public init() {}

    /// Present recognized text for review. Focused, key-capable (story 50).
    /// Replaces any panel already on screen.
    public func show(_ review: OCRReviewState, relativeTo anchor: NSRect?) {
        hide()

        let size = Self.panelSize
        let contentRect = NSRect(origin: .zero, size: size)
        let panel = OCRReviewPanel(contentRect: contentRect)
        panel.onRequestCopy = { [weak self] in self?.handleCopy() }
        panel.onRequestDismiss = { [weak self] in self?.handleDismiss() }

        let effect = NSVisualEffectView(frame: contentRect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let reviewView = OCRReviewView(frame: contentRect)
        reviewView.autoresizingMask = [.width, .height]
        reviewView.onCopy = { [weak self] in self?.handleCopy() }
        reviewView.onDismiss = { [weak self] in self?.handleDismiss() }
        effect.addSubview(reviewView)

        panel.contentView = effect
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size, relativeTo: anchor))

        reviewView.configure(with: review)

        self.panel = panel
        self.reviewView = reviewView

        // No open animation (story 56 / Reduce Motion).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        reviewView.focusText()
    }

    public func hide() {
        panel?.onRequestCopy = nil
        panel?.onRequestDismiss = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        reviewView = nil
    }

    // MARK: - Actions

    private func handleCopy() {
        guard reviewView?.hasCopyableText == true else {
            handleDismiss()
            return
        }
        onCopy?()
        hide()
    }

    private func handleDismiss() {
        onDismiss?()
        hide()
    }

    // MARK: - Placement

    /// Screen coordinates. Near `anchor` when given; otherwise centered on the
    /// screen under the mouse.
    private static func origin(for size: NSSize, relativeTo anchor: NSRect?) -> NSPoint {
        let screen: NSScreen?
        let target: NSPoint

        if let anchor {
            screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? fallbackVisibleFrame
            let x = anchor.midX - size.width / 2
            var y = anchor.minY - size.height - 8
            if y < visible.minY + 8 {
                y = anchor.maxY + 8
            }
            target = NSPoint(x: x, y: y)
        } else {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? fallbackVisibleFrame
            target = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }

        let visible = screen?.visibleFrame ?? fallbackVisibleFrame
        let x = min(max(target.x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(target.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private static var fallbackVisibleFrame: NSRect {
        NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
