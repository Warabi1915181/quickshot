import AppKit
import QuickShotCore

/// Owns the selection overlay window for one `SelectionSession`.
/// SHELL wires `onAreaSelected` / `onWindowSelected` / `onCancelled` / `onModeChanged`
/// to `workflow.dispatch`, and supplies `windowLookup` from the capture adapter.
@MainActor
public final class SelectionCoordinator {
    public init() {}

    /// Outgoing events — SHELL wires these to `workflow.dispatch`.
    public var onAreaSelected: ((CGRect) -> Void)?
    public var onWindowSelected: ((CGWindowID) -> Void)?
    public var onCancelled: (() -> Void)?
    public var onModeChanged: ((SelectionMode) -> Void)?
    /// Ask the app for window geometry under the pointer during window mode.
    /// Point and returned frame are Cocoa global points.
    public var windowLookup: ((CGPoint) -> (id: CGWindowID, frame: CGRect)?)?

    /// True from `begin` until `end`.
    public private(set) var isSelecting = false

    private var window: SelectionOverlayWindow?
    private var overlayView: SelectionOverlayView?
    private var mode: SelectionMode = .area
    /// Set once a terminal callback has fired; blocks double-dispatch.
    private var didFinish = false

    // MARK: - Session

    /// Begin a selection session. `session.frozenFrame` is the still picture to select against.
    public func begin(session: SelectionSession) {
        end()

        let frame = displayFrame(for: session)
        let window = SelectionOverlayWindow(frame: frame)
        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.frozenImage = NSImage(
            cgImage: session.frozenFrame.cgImage,
            size: NSSize(width: frame.width, height: frame.height)
        )
        view.mode = session.mode
        mode = session.mode

        view.onDragComplete = { [weak self] viewRect in
            self?.completeArea(viewRect)
        }
        view.onWindowSelected = { [weak self] id in
            self?.completeWindow(id)
        }
        view.onCancelled = { [weak self] in
            self?.completeCancel()
        }
        view.onRequestMode = { [weak self] requested in
            self?.userRequestedMode(requested)
        }
        view.windowLookup = { [weak self] point in
            self?.windowLookup?(point)
        }

        window.contentView = view
        self.window = window
        self.overlayView = view
        self.isSelecting = true
        self.didFinish = false

        present(window, view: view)
    }

    /// Tear down the overlay. Safe to call after a terminal callback (SHELL `endSelection`).
    public func end() {
        guard let window else {
            isSelecting = false
            didFinish = false
            overlayView = nil
            return
        }
        window.orderOut(nil)
        window.close()
        self.window = nil
        overlayView = nil
        isSelecting = false
        didFinish = false
    }

    /// Update mode from workflow (`selectionModeChanged`). Visual only; frozen frame stays.
    public func setMode(_ mode: SelectionMode) {
        self.mode = mode
        overlayView?.mode = mode
    }

    // MARK: - Terminal events

    private func completeArea(_ viewRect: NSRect) {
        guard isSelecting, !didFinish, let overlayView else { return }
        didFinish = true
        let rect = overlayView.globalRect(fromView: viewRect)
        // Auto-hide now so a slow SHELL cannot leave the overlay stuck; end() tears down fully.
        window?.orderOut(nil)
        onAreaSelected?(rect)
    }

    private func completeWindow(_ id: CGWindowID) {
        guard isSelecting, !didFinish else { return }
        didFinish = true
        window?.orderOut(nil)
        onWindowSelected?(id)
    }

    private func completeCancel() {
        guard isSelecting, !didFinish else { return }
        didFinish = true
        window?.orderOut(nil)
        onCancelled?()
    }

    private func userRequestedMode(_ requested: SelectionMode) {
        guard isSelecting, !didFinish else { return }
        if requested == .window && mode == .window {
            return
        }
        if requested == mode {
            return
        }
        setMode(requested)
        onModeChanged?(requested)
    }

    // MARK: - Presentation

    private func present(_ window: SelectionOverlayWindow, view: SelectionOverlayView) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            window.alphaValue = 1
        } else {
            window.alphaValue = 0
        }
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)

        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                window.animator().alphaValue = 1
            }
        }
    }

    private func displayFrame(for session: SelectionSession) -> NSRect {
        let bounds = session.displayBounds
        if bounds.width > 0, bounds.height > 0 {
            if let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, bounds) }) {
                // Cover the whole screen the session is for (v1 single display).
                return screen.frame
            }
            return bounds
        }
        return NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero
    }
}
