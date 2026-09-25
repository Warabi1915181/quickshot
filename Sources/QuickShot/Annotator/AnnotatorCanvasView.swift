import AppKit
import QuickShotCore

/// Draws `AnnotatorDocument` and hosts tool interaction.
///
/// Coordinate space: `Mark` geometry is image pixels, origin top-left (Models.swift).
/// This view is flipped (top-left origin), matching that space. Convert with
/// `imagePoint(fromView:)` / `viewPoint(fromImage:)` which apply `zoom`
/// and the letterboxed `imageDrawRect`. Store top-left pixel coords only — the
/// renderer (SYS) flips once and draws top-left rects.
@MainActor
final class AnnotatorCanvasView: NSView {
    var document: AnnotatorDocument {
        didSet { needsDisplay = true }
    }

    var activeTool: AnnotationTool = .arrow {
        didSet {
            if activeTool != oldValue {
                cancelPendingCrop()
                commitTextEditing()
            }
            needsDisplay = true
        }
    }

    var strokeColor: RGBAColor = .red {
        didSet { needsDisplay = true }
    }

    var strokeWidth: Double = 4 {
        didSet { needsDisplay = true }
    }

    /// View points per image pixel. 1.0 = one pixel per point.
    private(set) var zoom: CGFloat = 1

    private(set) var pendingCrop: CGRect? {
        didSet {
            if pendingCrop != oldValue {
                onCropStateChange?()
            }
        }
    }

    /// Mutate the document through the editor (undoable).
    var onApply: (((inout AnnotatorDocument) -> Void) -> Void)?
    /// Pending crop set/cleared — toolbar Apply/Cancel visibility.
    var onCropStateChange: (() -> Void)?

    // MARK: - Drag state (image pixel coords, top-left)

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var textOrigin: CGPoint?
    private var textEditor: NSTextField?
    private var cropDragMode: CropDragMode = .none
    private var hasFitOnce = false

    private enum CropDragMode: Equatable {
        case none
        case create
        case move
        case resize(CropHandle)
    }

    private enum CropHandle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private static let textFontSize: Double = 18
    private static let handleSize: CGFloat = 8
    private static let handleHitSlop: CGFloat = 6

    override init(frame frameRect: NSRect) {
        self.document = AnnotatorDocument(baseImage: CapturedImage(cgImage: Self.placeholderImage()))
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        self.document = AnnotatorDocument(baseImage: CapturedImage(cgImage: Self.placeholderImage()))
        super.init(coder: coder)
    }

    init(document: AnnotatorDocument) {
        self.document = document
        super.init(frame: .zero)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setDocument(_ document: AnnotatorDocument) {
        self.document = document
        pendingCrop = nil
        dragStart = nil
        dragCurrent = nil
        hasFitOnce = false
        commitTextEditing()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if !hasFitOnce {
            hasFitOnce = true
            zoomToFit()
        }
    }

    func setZoom(_ zoom: CGFloat) {
        self.zoom = max(0.1, min(zoom, 8))
        needsDisplay = true
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    /// Reset to 1.0 (100%).
    func zoomReset() { setZoom(1) }

    /// Fit image to current bounds (⌘0 with option, or initial placement helper).
    func zoomToFit() {
        let size = document.baseImage.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            setZoom(1)
            return
        }
        setZoom(min(bounds.width / size.width, bounds.height / size.height))
    }

    func cancelPendingCrop() {
        pendingCrop = nil
        dragStart = nil
        dragCurrent = nil
        cropDragMode = .none
        needsDisplay = true
    }

    func applyPendingCrop() {
        guard var rect = pendingCrop ?? cropRectFromDrag() else { return }
        rect = normalized(rect).intersection(CGRect(origin: .zero, size: document.baseImage.size))
        guard !rect.isEmpty else { return }
        onApply? { doc in
            doc.crop = rect
        }
        pendingCrop = nil
        dragStart = nil
        dragCurrent = nil
        cropDragMode = .none
        needsDisplay = true
    }

    // MARK: - Coordinate conversion (see header comment)

    private var imageDrawRect: CGRect {
        let imageSize = document.baseImage.size
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scaled = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
        let origin = CGPoint(
            x: (bounds.width - scaled.width) / 2,
            y: (bounds.height - scaled.height) / 2
        )
        return CGRect(origin: origin, size: scaled)
    }

    private func viewPoint(fromImage point: CGPoint) -> CGPoint {
        let rect = imageDrawRect
        return CGPoint(
            x: rect.origin.x + point.x * zoom,
            y: rect.origin.y + point.y * zoom
        )
    }

    private func imagePoint(fromView point: CGPoint) -> CGPoint {
        let rect = imageDrawRect
        return CGPoint(
            x: (point.x - rect.origin.x) / zoom,
            y: (point.y - rect.origin.y) / zoom
        )
    }

    private func viewRect(fromImage rect: CGRect) -> CGRect {
        let origin = viewPoint(fromImage: CGPoint(x: rect.minX, y: rect.minY))
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    private func imageSize() -> CGSize {
        document.baseImage.size
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        let size = imageSize()
        return CGPoint(
            x: min(max(point.x, 0), size.width),
            y: min(max(point.y, 0), size.height)
        )
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        CGRect(
            x: min(rect.minX, rect.maxX),
            y: min(rect.minY, rect.maxY),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private func cropRectFromDrag() -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = normalized(CGRect(origin: start, size: CGSize(width: current.x - start.x, height: current.y - start.y)))
        guard rect.width > 2, rect.height > 2 else { return nil }
        return rect
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let drawRect = imageDrawRect
        // NSImage.draw respects isFlipped → upright with top-left in this view.
        let base = NSImage(
            cgImage: document.baseImage.cgImage,
            size: document.baseImage.size
        )
        base.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        for mark in document.marks {
            draw(mark)
        }

        drawCropGuide()
        drawCropMarquee()
        drawDragPreview()
    }

    private func draw(_ mark: Mark) {
        switch mark {
        case let .arrow(_, start, end, color, width):
            drawArrow(start: start, end: end, color: color, width: width)

        case let .text(_, string, origin, color, fontSize):
            drawText(string, origin: origin, color: color, fontSize: fontSize)

        case let .rectangle(_, rect, stroke, strokeWidth):
            let path = NSBezierPath(rect: viewRect(fromImage: rect))
            path.lineWidth = CGFloat(strokeWidth) * zoom
            stroke.nsColor.setStroke()
            path.stroke()

        case let .ellipse(_, rect, stroke, strokeWidth):
            let path = NSBezierPath(ovalIn: viewRect(fromImage: rect))
            path.lineWidth = CGFloat(strokeWidth) * zoom
            stroke.nsColor.setStroke()
            path.stroke()

        case let .highlight(_, rect, color):
            // Multiply keeps content readable (story 40).
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setBlendMode(.multiply)
            color.nsColor.withAlphaComponent(0.45).setFill()
            viewRect(fromImage: rect).fill()
            context.restoreGState()

        case let .blur(_, rect, radius):
            drawBlur(rect: rect, radius: radius)
        }
    }

    private func drawArrow(start: CGPoint, end: CGPoint, color: RGBAColor, width: Double) {
        let startView = viewPoint(fromImage: start)
        let endView = viewPoint(fromImage: end)
        let lineWidth = max(1, CGFloat(width) * zoom)
        let headLength = max(10, lineWidth * 3.2)
        let dx = endView.x - startView.x
        let dy = endView.y - startView.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let ux = dx / length
        let uy = dy / length
        let shaftEnd = CGPoint(
            x: endView.x - ux * headLength * 0.85,
            y: endView.y - uy * headLength * 0.85
        )

        color.nsColor.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: startView)
        shaft.line(to: shaftEnd)
        shaft.stroke()

        // Filled triangle head (story 35).
        let angle = atan2(uy, ux)
        let wing = headLength * 0.42
        let left = CGPoint(
            x: endView.x - headLength * cos(angle) + wing * cos(angle + .pi / 2),
            y: endView.y - headLength * sin(angle) + wing * sin(angle + .pi / 2)
        )
        let right = CGPoint(
            x: endView.x - headLength * cos(angle) + wing * cos(angle - .pi / 2),
            y: endView.y - headLength * sin(angle) + wing * sin(angle - .pi / 2)
        )
        let head = NSBezierPath()
        head.move(to: endView)
        head.line(to: left)
        head.line(to: right)
        head.close()
        color.nsColor.setFill()
        head.fill()
    }

    private func drawText(_ string: String, origin: CGPoint, color: RGBAColor, fontSize: Double) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(fontSize) * zoom),
            .foregroundColor: color.nsColor,
        ]
        (string as NSString).draw(at: viewPoint(fromImage: origin), withAttributes: attrs)
    }

    /// Pixelate the base image under `rect` (story 39). Live preview approximates final flatten.
    private func drawBlur(rect: CGRect, radius: Double) {
        let clamped = normalized(rect).intersection(CGRect(origin: .zero, size: imageSize()))
        guard !clamped.isEmpty else { return }

        let source = document.baseImage.cgImage
        let pixelRect = CGRect(
            x: clamped.minX,
            y: clamped.minY,
            width: clamped.width,
            height: clamped.height
        ).integral
        guard let cropped = source.cropping(to: pixelRect) else { return }

        let block = max(2, radius)
        let smallW = max(1, Int(pixelRect.width / block))
        let smallH = max(1, Int(pixelRect.height / block))

        guard
            let smallCtx = CGContext(
                data: nil,
                width: smallW,
                height: smallH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let bigCtx = CGContext(
                data: nil,
                width: Int(pixelRect.width),
                height: Int(pixelRect.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return }

        // Downscale then upscale without interpolation (pixelate).
        smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let smallImage = smallCtx.makeImage() else { return }

        bigCtx.interpolationQuality = .none
        bigCtx.draw(smallImage, in: CGRect(x: 0, y: 0, width: pixelRect.width, height: pixelRect.height))
        guard let pixelated = bigCtx.makeImage() else { return }

        let target = viewRect(fromImage: clamped)
        NSImage(cgImage: pixelated, size: pixelRect.size).draw(
            in: target,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawCropGuide() {
        guard let crop = document.crop else { return }
        let cropView = viewRect(fromImage: crop)

        // Dim outside the crop so the kept region reads clearly.
        NSColor.black.withAlphaComponent(0.35).setFill()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: cropView).reversed)
        outside.windingRule = .evenOdd
        outside.fill()

        let border = NSBezierPath(rect: cropView)
        border.lineWidth = 1.5
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()
        border.setLineDash(nil, count: 0, phase: 0)
    }

    private func drawCropMarquee() {
        guard activeTool == .crop else { return }
        let rect = pendingCrop ?? cropRectFromDrag()
        guard let rect else {
            return
        }
        let cropView = viewRect(fromImage: rect)

        NSColor.black.withAlphaComponent(0.25).setFill()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: cropView).reversed)
        outside.windingRule = .evenOdd
        outside.fill()

        let border = NSBezierPath(rect: cropView)
        border.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        for handle in CropHandle.allCases {
            let point = handlePoint(handle, in: rect)
            let view = viewPoint(fromImage: point)
            let box = CGRect(
                x: view.x - Self.handleSize / 2,
                y: view.y - Self.handleSize / 2,
                width: Self.handleSize,
                height: Self.handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(roundedRect: box, xRadius: 1, yRadius: 1).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: box, xRadius: 1, yRadius: 1)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private func drawDragPreview() {
        guard activeTool != .crop, activeTool != .text, let start = dragStart, let current = dragCurrent else { return }
        let previewColor = strokeColor.nsColor
        previewColor.setStroke()
        previewColor.withAlphaComponent(0.35).setFill()

        switch activeTool {
        case .arrow:
            drawArrow(start: start, end: current, color: strokeColor, width: strokeWidth)
        case .rectangle:
            let path = NSBezierPath(rect: viewRect(fromImage: normalized(CGRect(
                x: start.x, y: start.y,
                width: current.x - start.x, height: current.y - start.y
            ))))
            path.lineWidth = CGFloat(strokeWidth) * zoom
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: viewRect(fromImage: normalized(CGRect(
                x: start.x, y: start.y,
                width: current.x - start.x, height: current.y - start.y
            ))))
            path.lineWidth = CGFloat(strokeWidth) * zoom
            path.stroke()
        case .highlight:
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setBlendMode(.multiply)
            strokeColor.nsColor.withAlphaComponent(0.45).setFill()
            viewRect(fromImage: normalized(CGRect(
                x: start.x, y: start.y,
                width: current.x - start.x, height: current.y - start.y
            ))).fill()
            context.restoreGState()
        case .blur:
            if let rect = cropRectFromDragLike() {
                drawBlur(rect: rect, radius: max(8, strokeWidth * 3))
            }
        case .crop, .text:
            break
        }
    }

    private func cropRectFromDragLike() -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = normalized(CGRect(
            x: start.x, y: start.y,
            width: current.x - start.x,
            height: current.y - start.y
        ))
        guard rect.width > 2, rect.height > 2 else { return nil }
        return rect
    }

    private func handlePoint(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)

        let view = convert(event.locationInWindow, from: nil)
        let image = clampToImage(imagePoint(fromView: view))

        switch activeTool {
        case .text:
            beginTextEditing(at: image)

        case .crop:
            if let hit = hitTestHandle(at: image, view: view), let crop = activeCropRect() {
                cropDragMode = .resize(hit)
                dragStart = image
                pendingCrop = crop
            } else if let crop = activeCropRect(), crop.insetBy(dx: -2, dy: -2).contains(image) {
                cropDragMode = .move
                dragStart = image
                pendingCrop = crop
            } else {
                cropDragMode = .create
                dragStart = image
                dragCurrent = image
                pendingCrop = nil
            }
            needsDisplay = true

        default:
            cropDragMode = .none
            dragStart = image
            dragCurrent = image
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        let image = clampToImage(imagePoint(fromView: view))

        switch activeTool {
        case .text:
            return

        case .crop:
            handleCropDrag(to: image)

        default:
            dragCurrent = image
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragCurrent = nil
            cropDragMode = .none
        }

        switch activeTool {
        case .text:
            return

        case .crop:
            if cropDragMode == .create, let rect = cropRectFromDrag() {
                pendingCrop = rect
            }
            needsDisplay = true
            return

        case .arrow:
            guard let start = dragStart, let end = dragCurrent,
                  hypot(end.x - start.x, end.y - start.y) > 2 else { return }
            commitTextEditing()
            let color = strokeColor
            let width = strokeWidth
            onApply? { doc in
                doc.marks.append(.arrow(id: UUID(), start: start, end: end, color: color, width: width))
            }

        case .rectangle:
            guard let rect = cropRectFromDragLike() else { return }
            let color = strokeColor
            let width = strokeWidth
            onApply? { doc in
                doc.marks.append(.rectangle(id: UUID(), rect: rect, stroke: color, strokeWidth: width))
            }

        case .ellipse:
            guard let rect = cropRectFromDragLike() else { return }
            let color = strokeColor
            let width = strokeWidth
            onApply? { doc in
                doc.marks.append(.ellipse(id: UUID(), rect: rect, stroke: color, strokeWidth: width))
            }

        case .highlight:
            guard let rect = cropRectFromDragLike() else { return }
            let color = strokeColor
            onApply? { doc in
                doc.marks.append(.highlight(id: UUID(), rect: rect, color: color))
            }

        case .blur:
            guard let rect = cropRectFromDragLike() else { return }
            let radius = max(8, strokeWidth * 3)
            onApply? { doc in
                doc.marks.append(.blur(id: UUID(), rect: rect, radius: radius))
            }
        }
    }

    private func activeCropRect() -> CGRect? {
        pendingCrop ?? document.crop
    }

    private func hitTestHandle(at imagePoint: CGPoint, view viewPoint: CGPoint) -> CropHandle? {
        guard let rect = activeCropRect() else { return nil }
        let slop = Self.handleHitSlop / zoom
        for handle in CropHandle.allCases {
            let point = handlePoint(handle, in: rect)
            if abs(point.x - imagePoint.x) <= slop, abs(point.y - imagePoint.y) <= slop {
                return handle
            }
        }
        return nil
    }

    private func handleCropDrag(to image: CGPoint) {
        guard let start = dragStart else { return }
        let delta = CGPoint(x: image.x - start.x, y: image.y - start.y)
        let size = imageSize()
        let bounds = CGRect(origin: .zero, size: size)

        switch cropDragMode {
        case .none:
            return

        case .create:
            dragCurrent = image
            needsDisplay = true

        case .move:
            guard var rect = pendingCrop else { return }
            rect.origin.x = min(max(rect.origin.x + delta.x, 0), max(0, size.width - rect.width))
            rect.origin.y = min(max(rect.origin.y + delta.y, 0), max(0, size.height - rect.height))
            pendingCrop = rect
            dragStart = image
            needsDisplay = true

        case .resize(let handle):
            guard let rect = pendingCrop else { return }
            var minX = rect.minX
            var minY = rect.minY
            var maxX = rect.maxX
            var maxY = rect.maxY

            switch handle {
            case .topLeft, .left, .bottomLeft: minX = image.x
            case .topRight, .right, .bottomRight: maxX = image.x
            default: break
            }
            switch handle {
            case .topLeft, .top, .topRight: minY = image.y
            case .bottomLeft, .bottom, .bottomRight: maxY = image.y
            default: break
            }

            var next = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            next = next.intersection(bounds)
            if next.width > 2, next.height > 2 {
                pendingCrop = next
                dragStart = image
            }
            needsDisplay = true
        }
    }

    // MARK: - Text tool (story 36)

    private func beginTextEditing(at origin: CGPoint) {
        textOrigin = origin
        let field = NSTextField(frame: .zero)
        field.font = NSFont.systemFont(ofSize: Self.textFontSize * zoom)
        field.textColor = strokeColor.nsColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.isBordered = true
        field.focusRingType = .default
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        field.target = self
        field.action = #selector(textEditorCommitted(_:))
        field.setAccessibilityLabel("Text")

        let originView = viewPoint(fromImage: origin)
        let width = max(120, bounds.width - originView.x - 8)
        field.frame = CGRect(x: originView.x, y: originView.y - 4, width: min(width, 360), height: 28)
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
    }

    @objc private func textEditorCommitted(_ sender: NSTextField) {
        commitTextEditing()
    }

    func commitTextEditing() {
        guard let field = textEditor else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textOrigin
        field.removeFromSuperview()
        textEditor = nil
        textOrigin = nil

        guard !string.isEmpty, let origin else { return }
        let color = strokeColor
        let fontSize = Self.textFontSize
        onApply? { doc in
            doc.marks.append(.text(id: UUID(), string: string, origin: origin, color: color, fontSize: fontSize))
        }
    }

    func cancelTextEditing() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        textOrigin = nil
    }

    var isEditingText: Bool { textEditor != nil }

    // MARK: - Keys (tools 1–7, zoom)

    /// Returns true when the event was handled.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Escape cancels the in-flight text edit (story 36).
        if textEditor != nil {
            if event.keyCode == 53 {
                cancelTextEditing()
                return true
            }
            // Otherwise the field editor owns keys while typing.
            return false
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                zoomIn()
                return true
            case "-":
                zoomOut()
                return true
            case "0":
                zoomReset()
                return true
            default:
                break
            }
        }

        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            return false
        }

        switch event.charactersIgnoringModifiers {
        case "1":
            activeTool = .arrow
            return true
        case "2":
            activeTool = .text
            return true
        case "3":
            activeTool = .rectangle
            return true
        case "4":
            activeTool = .ellipse
            return true
        case "5":
            activeTool = .highlight
            return true
        case "6":
            activeTool = .blur
            return true
        case "7":
            activeTool = .crop
            return true
        case "\u{1b}":
            // Escape: drop pending crop (text handled above).
            if pendingCrop != nil {
                cancelPendingCrop()
                return true
            }
            return false
        default:
            return false
        }
    }

    private static func placeholderImage() -> CGImage {
        let width = 480
        let height = 320
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
