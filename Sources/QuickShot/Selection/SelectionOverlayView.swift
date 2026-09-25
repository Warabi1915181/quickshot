import AppKit
import QuickShotCore

/// Draws the frozen frame, scrim + selection / window highlight, and hint chrome.
/// Geometry in view points (non-flipped, y-up) matches Cocoa global via the window frame.
final class SelectionOverlayView: NSView {
    var mode: SelectionMode = .area {
        didSet {
            guard mode != oldValue else { return }
            if mode != .window {
                highlightWindowID = nil
                highlightRect = nil
            }
            updateHint()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var frozenImage: NSImage?
    /// Live drag rect in view coordinates. `nil` when idle.
    var selectionRect: NSRect?
    /// Window outline in view coordinates (window mode).
    var highlightRect: NSRect?
    var highlightWindowID: CGWindowID?

    /// Rect is view coordinates; coordinator maps to Cocoa global.
    var onDragComplete: ((NSRect) -> Void)?
    var onWindowSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?
    var onRequestMode: ((SelectionMode) -> Void)?
    /// Point is Cocoa global; frame is Cocoa global.
    var windowLookup: ((CGPoint) -> (id: CGWindowID, frame: CGRect)?)?

    private var dragStart: NSPoint?
    private let hintContainer = NSVisualEffectView()
    private let hintLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupHint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .window ? .pointingHand : .crosshair)
    }

    override func layout() {
        super.layout()
        layoutHint()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let image = frozenImage {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSColor.black.setFill()
            bounds.fill()
        }

        let cutout = activeCutout
        NSGraphicsContext.saveGraphicsState()
        let scrim = NSBezierPath(rect: bounds)
        if let cutout, !cutout.isEmpty {
            scrim.append(NSBezierPath(rect: cutout))
            scrim.windingRule = .evenOdd
        }
        scrim.addClip()
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()

        if mode == .window {
            drawWindowHighlight()
        } else if let cutout, !cutout.isEmpty {
            drawSelectionRect(cutout)
        }
    }

    private var activeCutout: NSRect? {
        switch mode {
        case .window:
            return highlightRect
        case .area, .ocrRegion:
            return selectionRect
        }
    }

    private func drawSelectionRect(_ rect: NSRect) {
        let stroke = mode == .ocrRegion ? NSColor.controlAccentColor : NSColor.white
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        stroke.setStroke()
        path.stroke()

        let inner = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        inner.stroke()
    }

    private func drawWindowHighlight() {
        guard let highlightRect, !highlightRect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let path = NSBezierPath(rect: highlightRect)
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Hint chrome

    private func setupHint() {
        hintContainer.material = .hudWindow
        hintContainer.blendingMode = .withinWindow
        hintContainer.state = .active
        hintContainer.wantsLayer = true
        hintContainer.layer?.cornerRadius = 8
        hintContainer.layer?.masksToBounds = true

        hintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = .labelColor
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail

        hintContainer.addSubview(hintLabel)
        addSubview(hintContainer)
        updateHint()
    }

    private func updateHint() {
        hintLabel.stringValue = Self.hintText(for: mode)
        hintLabel.sizeToFit()
        layoutHint()
        needsDisplay = true
    }

    static func hintText(for mode: SelectionMode) -> String {
        switch mode {
        case .area:
            return "Drag to select · W window · O OCR · Esc cancel"
        case .window:
            // W stays in window mode (no toggle back to area).
            return "Click a window · O OCR · Esc cancel"
        case .ocrRegion:
            return "Drag to select · W window · Esc cancel"
        }
    }

    private func layoutHint() {
        let labelSize = hintLabel.frame.size
        let padX: CGFloat = 14
        let padY: CGFloat = 8
        let size = NSSize(width: labelSize.width + padX * 2, height: labelSize.height + padY * 2)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: 28)
        hintContainer.frame = NSRect(origin: origin, size: size)
        hintLabel.frame = NSRect(
            x: padX,
            y: padY,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if mode == .window {
            updateWindowHighlight(at: event)
            if let id = highlightWindowID {
                onWindowSelected?(id)
            }
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(origin: dragStart ?? .zero, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mode == .window {
            updateWindowHighlight(at: event)
            return
        }
        guard let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = Self.rect(from: start, to: current)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .window {
            updateWindowHighlight(at: event)
            return
        }
        guard let start = dragStart else { return }
        dragStart = nil
        let current = convert(event.locationInWindow, from: nil)
        let rect = Self.rect(from: start, to: current)
        // Tiny / zero drag: ignore, never emit an empty capture.
        guard rect.width >= 2, rect.height >= 2 else {
            selectionRect = nil
            needsDisplay = true
            return
        }
        selectionRect = rect
        needsDisplay = true
        onDragComplete?(rect)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        updateWindowHighlight(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard mode == .window else { return }
        highlightRect = nil
        highlightWindowID = nil
        needsDisplay = true
    }

    private func updateWindowHighlight(at event: NSEvent) {
        let global = globalPoint(fromWindow: event.locationInWindow)
        guard let hit = windowLookup?(global) else {
            highlightRect = nil
            highlightWindowID = nil
            needsDisplay = true
            return
        }
        highlightWindowID = hit.id
        highlightRect = viewRect(fromGlobal: hit.frame)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 || chars == "\u{1b}" {
            dragStart = nil
            onCancelled?()
            return
        }
        // Mode switches stay live mid-session; ignore while a drag is in progress.
        guard dragStart == nil else {
            super.keyDown(with: event)
            return
        }
        switch chars {
        case "w":
            // W always targets window mode; already-window stays (no toggle).
            onRequestMode?(.window)
        case "o":
            onRequestMode?(.ocrRegion)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Coordinates

    private static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func globalPoint(fromWindow p: NSPoint) -> CGPoint {
        guard let window else { return p }
        return window.convertPoint(toScreen: p)
    }

    private func viewRect(fromGlobal global: CGRect) -> NSRect {
        guard let window else { return global }
        let oWindow = window.convertPoint(fromScreen: global.origin)
        let oView = convert(oWindow, from: nil)
        return NSRect(origin: oView, size: global.size)
    }

    /// View rect → Cocoa global points (origin bottom-left of primary display).
    func globalRect(fromView viewRect: NSRect) -> CGRect {
        guard let window else { return viewRect }
        let minWindow = convert(NSPoint(x: viewRect.minX, y: viewRect.minY), to: nil)
        let maxWindow = convert(NSPoint(x: viewRect.maxX, y: viewRect.maxY), to: nil)
        let gMin = window.convertPoint(toScreen: minWindow)
        let gMax = window.convertPoint(toScreen: maxWindow)
        return CGRect(
            x: min(gMin.x, gMax.x),
            y: min(gMin.y, gMax.y),
            width: abs(gMax.x - gMin.x),
            height: abs(gMax.y - gMin.y)
        )
    }
}
