import CoreGraphics
import Foundation
import ImageIO
@testable import QuickShotCore
import XCTest

// MARK: - Image helpers

/// Small RGBA 8-bit solid image for tests.
func makeTestImage(width: Int, height: Int, color: RGBAColor) -> CapturedImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        preconditionFailure("test image context")
    }
    ctx.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage() else {
        preconditionFailure("test image makeImage")
    }
    return CapturedImage(cgImage: image)
}

/// Two-band image: visual top half `top`, bottom half `bottom` (Mark space, origin top-left).
func makeSplitTestImage(width: Int, height: Int, top: RGBAColor, bottom: RGBAColor) -> CapturedImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        preconditionFailure("test image context")
    }
    // CG context Y-up: high Y is the visual top.
    let mid = CGFloat(height) / 2
    ctx.setFillColor(red: bottom.red, green: bottom.green, blue: bottom.blue, alpha: bottom.alpha)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: mid))
    ctx.setFillColor(red: top.red, green: top.green, blue: top.blue, alpha: top.alpha)
    ctx.fill(CGRect(x: 0, y: mid, width: CGFloat(width), height: mid))
    guard let image = ctx.makeImage() else {
        preconditionFailure("test image makeImage")
    }
    return CapturedImage(cgImage: image)
}

/// RGBA sample at image pixel (origin top-left). ~255 = bright.
func samplePixel(_ image: CapturedImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
    let w = image.pixelWidth
    let h = image.pixelHeight
    guard x >= 0, y >= 0, x < w, y < h else { return nil }
    var data = [UInt8](repeating: 0, count: max(w * h * 4, 4))
    guard let ctx = CGContext(
        data: &data,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    // draw() buffer row 0 == CGImage.cropping y=0 (top). Mark space matches.
    let i = (y * w + x) * 4
    return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
}

/// Count pixels darker than `threshold` in a rect (Mark space, origin top-left).
func countDarkPixels(
    _ image: CapturedImage,
    in rect: CGRect,
    threshold: Int = 128
) -> Int {
    let x0 = max(Int(rect.minX), 0)
    let y0 = max(Int(rect.minY), 0)
    let x1 = min(Int(rect.maxX), image.pixelWidth)
    let y1 = min(Int(rect.maxY), image.pixelHeight)
    var count = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            if let p = samplePixel(image, x: x, y: y), p.r < threshold, p.a > 200 {
                count += 1
            }
        }
    }
    return count
}

/// Bounding box of dark pixels in the whole image (Mark space). `nil` when blank.
func darkPixelBounds(_ image: CapturedImage, threshold: Int = 128) -> CGRect? {
    var minX = image.pixelWidth
    var minY = image.pixelHeight
    var maxX = -1
    var maxY = -1
    for y in 0..<image.pixelHeight {
        for x in 0..<image.pixelWidth {
            guard let p = samplePixel(image, x: x, y: y), p.r < threshold, p.a > 200 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= 0, maxY >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Write a real PNG to a temp file (for `ocrImage` load tests).
func writePNGToTemp(_ image: CapturedImage, name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw MockError.boom
    }
    CGImageDestinationAddImage(dest, image.cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw MockError.boom
    }
    return url
}

// MARK: - Harness

@MainActor
final class WorkflowHarness {
    let capture: MockCaptureService
    let ocr: MockOCRService
    let clipboard: MockClipboardService
    let files: MockFileService
    let shortcuts: MockShortcutService
    let renderer: MockImageRenderer
    let workflow: CaptureWorkflow

    private(set) var effects: [WorkflowEffect] = []
    private(set) var states: [WorkflowState] = []

    var state: WorkflowState { workflow.state }
    var lastEffect: WorkflowEffect? { effects.last }

    init(preferences: AppPreferences = AppPreferences()) {
        let capture = MockCaptureService()
        let ocr = MockOCRService()
        let clipboard = MockClipboardService()
        let files = MockFileService()
        let shortcuts = MockShortcutService()
        let renderer = MockImageRenderer()

        self.capture = capture
        self.ocr = ocr
        self.clipboard = clipboard
        self.files = files
        self.shortcuts = shortcuts
        self.renderer = renderer

        let adapters = SystemAdapters(
            capture: capture,
            ocr: ocr,
            clipboard: clipboard,
            files: files,
            shortcuts: shortcuts
        )
        let workflow = CaptureWorkflow(
            adapters: adapters,
            renderer: renderer,
            preferences: preferences
        )
        self.workflow = workflow

        workflow.onEffect = { [weak self] effect in
            self?.effects.append(effect)
        }
        workflow.onStateChange = { [weak self] state in
            self?.states.append(state)
        }
    }

    /// Await async dispatch work (capture / OCR).
    func drain() async {
        await workflow.waitForInFlightWork()
    }

    /// Drop collected effects (keeps state / mock call logs).
    func clearEffects() {
        effects.removeAll()
    }

    // MARK: Effect queries

    func effectCount(_ match: (WorkflowEffect) -> Bool) -> Int {
        effects.filter(match).count
    }

    func containsEffect(_ match: (WorkflowEffect) -> Bool) -> Bool {
        effects.contains(where: match)
    }

    func thumbnailShownIDs() -> [PendingCapture.ID] {
        effects.compactMap {
            if case let .showThumbnail(item) = $0 { return item.id }
            return nil
        }
    }

    func hiddenThumbnailIDs() -> [PendingCapture.ID] {
        effects.compactMap {
            if case let .hideThumbnail(id) = $0 { return id }
            return nil
        }
    }

    func errorEffects() -> [(WorkflowError, Bool)] {
        effects.compactMap {
            if case let .showError(error, available) = $0 { return (error, available) }
            return nil
        }
    }
}

// MARK: - Assertion helpers

@MainActor
func XCTAssertEffect(
    _ harness: WorkflowHarness,
    matches match: (WorkflowEffect) -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(harness.containsEffect(match), message, file: file, line: line)
}

@MainActor
func XCTAssertNoEffect(
    _ harness: WorkflowHarness,
    matches match: (WorkflowEffect) -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(harness.containsEffect(match), message, file: file, line: line)
}
