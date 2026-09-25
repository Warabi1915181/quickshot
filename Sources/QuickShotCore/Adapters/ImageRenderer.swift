import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Flattens `AnnotatorDocument` (marks + crop) into a bitmap.
///
/// Coordinates: image pixel space, **origin top-left** (matches `Mark`).
/// The CG context is flipped once at the start (translate + scale Y) so mark
/// geometry can be used as-is. Image draws compensate that flip per call.
public final class ImageRenderer: ImageRendering, @unchecked Sendable {

    public init() {}

    public func render(_ document: AnnotatorDocument) throws -> CapturedImage {
        let base = document.baseImage.cgImage
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else {
            throw WorkflowError.captureFailed("render")
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkflowError.captureFailed("render")
        }

        // Flip once: user space becomes top-left origin, Y down (mark space).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        drawImage(base, in: CGRect(x: 0, y: 0, width: width, height: height), on: context)

        for mark in document.marks {
            try draw(mark, on: context, width: width, height: height)
        }

        guard let flattened = context.makeImage() else {
            throw WorkflowError.captureFailed("render")
        }

        guard let crop = document.crop else {
            return CapturedImage(cgImage: flattened)
        }

        // `crop` is top-left origin pixel rect — same space as CGImage.cropping(to:).
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var pixelCrop = crop.integral.intersection(bounds)
        if pixelCrop.width < 1 || pixelCrop.height < 1 {
            let clampedX = min(max(crop.origin.x, 0), CGFloat(max(width - 1, 0)))
            let clampedY = min(max(crop.origin.y, 0), CGFloat(max(height - 1, 0)))
            let clampedW = min(max(crop.width, 1), CGFloat(width) - clampedX)
            let clampedH = min(max(crop.height, 1), CGFloat(height) - clampedY)
            pixelCrop = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
                .intersection(bounds)
        }
        guard pixelCrop.width >= 1, pixelCrop.height >= 1,
              let cropped = flattened.cropping(to: pixelCrop)
        else {
            throw WorkflowError.captureFailed("render")
        }
        return CapturedImage(cgImage: cropped)
    }

    // MARK: - Marks

    private func draw(_ mark: Mark, on context: CGContext, width: Int, height: Int) throws {
        switch mark {
        case let .arrow(_, start, end, color, lineWidth):
            drawArrow(from: start, to: end, color: color, width: lineWidth, on: context)

        case let .text(_, string, origin, color, fontSize):
            drawText(string, origin: origin, color: color, fontSize: fontSize, on: context)

        case let .rectangle(_, rect, stroke, strokeWidth):
            // Transparent fill, visible stroke (story 37).
            context.saveGState()
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(strokeWidth)
            context.stroke(rect)
            context.restoreGState()

        case let .ellipse(_, rect, stroke, strokeWidth):
            context.saveGState()
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(strokeWidth)
            context.strokeEllipse(in: rect)
            context.restoreGState()

        case let .highlight(_, rect, color):
            // Translucent multiply so underlying content stays visible (story 40).
            context.saveGState()
            context.setBlendMode(.multiply)
            context.setFillColor(color.withAlpha(0.35).cgColor)
            context.fill(rect)
            context.restoreGState()

        case let .blur(_, rect, radius):
            try applyBlur(rect: rect, radius: radius, on: context, width: width, height: height)
        }
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: RGBAColor,
        width lineWidth: Double,
        on context: CGContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return }

        let ux = dx / length
        let uy = dy / length
        let headLength = max(lineWidth * 3.0, 8.0)
        let headHalf = headLength * 0.45
        let shaftEnd = CGPoint(
            x: end.x - ux * headLength * 0.55,
            y: end.y - uy * headLength * 0.55
        )

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: shaftEnd)
        context.strokePath()

        let px = -uy
        let py = ux
        context.move(to: end)
        context.addLine(to: CGPoint(x: shaftEnd.x + px * headHalf, y: shaftEnd.y + py * headHalf))
        context.addLine(to: CGPoint(x: shaftEnd.x - px * headHalf, y: shaftEnd.y - py * headHalf))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private func drawText(
        _ string: String,
        origin: CGPoint,
        color: RGBAColor,
        fontSize: Double,
        on context: CGContext
    ) {
        guard !string.isEmpty else { return }
        context.saveGState()
        // Context is Y-down (flipped). textMatrix scale(1,-1) keeps glyphs upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        guard let font = CTFontCreateUIFontForLanguage(.system, CGFloat(fontSize), nil) else {
            context.restoreGState()
            return
        }
        let ascent = CTFontGetAscent(font)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            string as CFString,
            attributes as CFDictionary
        ) else {
            context.restoreGState()
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        // `origin` is top-left of the text block in mark space (Y-down).
        context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Pixelate the rect so content is concealed (story 39). Reads current bitmap, writes back.
    private func applyBlur(
        rect: CGRect,
        radius: Double,
        on context: CGContext,
        width: Int,
        height: Int
    ) throws {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width >= 1, clipped.height >= 1 else { return }
        guard let snapshot = context.makeImage() else {
            throw WorkflowError.captureFailed("render")
        }

        // CGImage.cropping(to:) is top-left origin — same as mark space.
        guard let patch = snapshot.cropping(to: clipped) else { return }

        let block = max(2, Int(radius.rounded()))
        let smallW = max(1, Int(clipped.width) / block)
        let smallH = max(1, Int(clipped.height) / block)

        guard let smallContext = CGContext(
            data: nil,
            width: smallW,
            height: smallH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkflowError.captureFailed("render")
        }
        smallContext.interpolationQuality = .low
        smallContext.draw(
            patch,
            in: CGRect(x: 0, y: 0, width: smallW, height: smallH)
        )
        guard let pixelated = smallContext.makeImage() else {
            throw WorkflowError.captureFailed("render")
        }

        context.saveGState()
        context.interpolationQuality = .none
        drawImage(pixelated, in: clipped, on: context)
        context.restoreGState()
    }

    /// Draw `image` upright into the flipped (top-left / Y-down) context at `rect`.
    private func drawImage(_ image: CGImage, in rect: CGRect, on context: CGContext) {
        context.saveGState()
        // Undo the global Y flip for this draw so the bitmap is not upside-down.
        context.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}

private extension RGBAColor {
    func withAlpha(_ value: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: value)
    }

    var cgColor: CGColor {
        NSColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        ).cgColor
    }
}
