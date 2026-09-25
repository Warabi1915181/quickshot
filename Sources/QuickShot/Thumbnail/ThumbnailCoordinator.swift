import AppKit
import QuickShotCore

/// Floating thumbnail UI (stories 19–24, 26–33, 51, 55).
/// One `ThumbnailPanel` per pending capture. Never auto-dismisses. Never takes key focus.
@MainActor
public final class ThumbnailCoordinator {
    public init() {}

    /// Outgoing — SHELL wires to `workflow.dispatch`.
    public var onCopy: ((PendingCapture.ID) -> Void)?
    public var onSave: ((PendingCapture.ID) -> Void)?
    public var onSaveAs: ((PendingCapture.ID) -> Void)?
    public var onDiscard: ((PendingCapture.ID) -> Void)?
    public var onOpenAnnotator: ((PendingCapture.ID) -> Void)?
    public var onDragCompleted: ((PendingCapture.ID) -> Void)?
    public var onDragFailed: ((PendingCapture.ID) -> Void)?

    /// Image data for the drag promise. SHELL supplies PNG encoding or the CapturedImage.
    public var pngDataForDrag: ((PendingCapture.ID) -> Data?)?

    private var controllers: [PendingCapture.ID: ThumbnailItemController] = [:]
    private var order: [PendingCapture.ID] = []
    private var position: ThumbnailPosition = .bottomLeading

    private enum Metrics {
        static let edgeMargin: CGFloat = 20
        static let stackOffset: CGFloat = 14
    }

    // MARK: - Public API

    /// Show (or refresh) a thumbnail for this pending capture.
    public func show(_ item: PendingCapture, position: ThumbnailPosition) {
        self.position = position
        if let existing = controllers[item.id] {
            existing.update(with: item)
        } else {
            let controller = ThumbnailItemController(item: item)
            wire(controller)
            controllers[item.id] = controller
            order.append(item.id)
        }
        restack(position: position)
        controllers[item.id]?.show()
    }

    public func hide(id: PendingCapture.ID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.close()
        order.removeAll { $0 == id }
        restack(position: position)
    }

    public func hideAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
        order.removeAll()
    }

    public func restack(position: ThumbnailPosition) {
        self.position = position
        let screen = targetScreen()
        let visible = order.compactMap { controllers[$0] }
        for (index, controller) in visible.enumerated() {
            let size = controller.preferredSize
            let origin = stackOrigin(
                for: index,
                size: size,
                position: position,
                screen: screen
            )
            controller.place(origin: origin)
            controller.show()
        }
    }

    // MARK: - Layout

    private func targetScreen() -> NSScreen {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Oldest at the anchor corner; each next item offsets along the stacking axis (story 24).
    private func stackOrigin(
        for index: Int,
        size: CGSize,
        position: ThumbnailPosition,
        screen: NSScreen
    ) -> NSPoint {
        let frame = screen.frame
        let offset = Metrics.stackOffset * CGFloat(index)

        let x: CGFloat
        switch position {
        case .bottomLeading, .topLeading:
            x = frame.minX + Metrics.edgeMargin
        case .bottomTrailing, .topTrailing:
            x = frame.maxX - Metrics.edgeMargin - size.width
        }

        let y: CGFloat
        switch position {
        case .bottomLeading, .bottomTrailing:
            y = frame.minY + Metrics.edgeMargin + offset
        case .topLeading, .topTrailing:
            y = frame.maxY - Metrics.edgeMargin - size.height - offset
        }

        return NSPoint(x: x, y: y)
    }

    // MARK: - Wiring

    private func wire(_ controller: ThumbnailItemController) {
        let id = controller.id
        controller.onCopy = { [weak self] in self?.onCopy?(id) }
        controller.onSave = { [weak self] in self?.onSave?(id) }
        controller.onSaveAs = { [weak self] in self?.onSaveAs?(id) }
        controller.onAnnotate = { [weak self] in self?.onOpenAnnotator?(id) }
        controller.onDiscard = { [weak self] in self?.onDiscard?(id) }
        controller.onDragCompleted = { [weak self] in self?.onDragCompleted?(id) }
        controller.onDragFailed = { [weak self] in self?.onDragFailed?(id) }
        controller.pngDataProvider = { [weak self] in self?.pngDataForDrag?(id) }
    }
}
