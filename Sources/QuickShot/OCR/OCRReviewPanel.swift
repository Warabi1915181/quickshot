import AppKit

/// Focused, key-capable panel for OCR review (story 50). Unlike thumbnails, this
/// surface takes key status so Return / Escape arrive here.
@MainActor
final class OCRReviewPanel: NSPanel {
    var onRequestCopy: (() -> Void)?
    var onRequestDismiss: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return, 53 = Escape (story 50)
        if event.keyCode == 36 {
            onRequestCopy?()
            return
        }
        if event.keyCode == 53 {
            onRequestDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        onRequestCopy?()
    }

    override func cancelOperation(_ sender: Any?) {
        onRequestDismiss?()
    }
}
