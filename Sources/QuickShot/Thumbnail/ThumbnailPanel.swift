import AppKit
import QuickShotCore

/// Non-key floating panel for one pending capture (stories 19, 23).
final class ThumbnailPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // The card view draws its own rounded shadow; a window shadow would add
        // a second, square one around the panel's transparent margin.
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        isRestorable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one thumbnail panel for one `PendingCapture`.
@MainActor
final class ThumbnailItemController {
    let id: PendingCapture.ID
    private(set) var panel: ThumbnailPanel
    private let thumbnailView: ThumbnailView
    private var dragPayload: ThumbnailDragPayload?
    private var item: PendingCapture

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDragCompleted: (() -> Void)?
    var onDragFailed: (() -> Void)?
    var pngDataProvider: (() -> Data?)?

    init(item: PendingCapture) {
        self.item = item
        self.id = item.id
        let size = ThumbnailView.contentSize(forPixelSize: item.image.size)
        let panel = ThumbnailPanel(contentRect: NSRect(origin: .zero, size: size))
        self.panel = panel
        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size))
        view.setAccessibilityLabel("Capture thumbnail")
        self.thumbnailView = view
        panel.contentView = view

        view.onCopy = { [weak self] in self?.onCopy?() }
        view.onSave = { [weak self] in self?.onSave?() }
        view.onSaveAs = { [weak self] in self?.onSaveAs?() }
        view.onAnnotate = { [weak self] in self?.onAnnotate?() }
        view.onDiscard = { [weak self] in self?.onDiscard?() }
        view.onDragRequested = { [weak self] event in self?.beginDrag(with: event) }

        applyImage()
    }

    func update(with item: PendingCapture) {
        self.item = item
        applyImage()
    }

    var preferredSize: CGSize {
        ThumbnailView.contentSize(forPixelSize: item.image.size)
    }

    func place(origin: NSPoint) {
        panel.setFrame(NSRect(origin: origin, size: preferredSize), display: true)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
        dragPayload = nil
    }

    private func applyImage() {
        // Point size must stay near the fitted thumbnail size. `.zero` adopts the
        // CGImage's pixel size, and NSImageView's required compression resistance
        // then blows the panel out to pixelWidth (full-screen bar bug).
        let fitted = ThumbnailView.fittedImageSize(forPixelSize: item.image.size)
        let image = NSImage(cgImage: item.image.cgImage, size: fitted)
        thumbnailView.update(image: image)
        panel.setContentSize(preferredSize)
    }

    private func beginDrag(with event: NSEvent) {
        let payload = ThumbnailDragPayload(
            captureID: id,
            image: item.image,
            pngData: { [weak self] in self?.pngDataProvider?() },
            onCompleted: { [weak self] in
                self?.dragPayload = nil
                self?.onDragCompleted?()
            },
            onFailed: { [weak self] in
                self?.dragPayload = nil
                self?.onDragFailed?()
            }
        )
        dragPayload = payload
        guard let contentView = panel.contentView else {
            dragPayload = nil
            onDragFailed?()
            return
        }
        payload.begin(in: contentView, event: event)
    }
}
