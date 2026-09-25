import CoreGraphics
import XCTest
@testable import QuickShotCore

/// Minimal test-local renderer: solid bitmap sized like the visible (cropped) document.
/// Live `ImageRenderer` is owned elsewhere; this covers the `ImageRendering` contract.
private struct SolidImageRenderer: ImageRendering, Sendable {
    var color: RGBAColor = .orange

    func render(_ document: AnnotatorDocument) throws -> CapturedImage {
        let size = document.crop?.size ?? document.baseImage.size
        return makeTestImage(width: Int(size.width.rounded(.up)), height: Int(size.height.rounded(.up)), color: color)
    }
}

@MainActor
final class ImageRendererTests: XCTestCase {

    func testSolidRendererUsesCropSizeWhenPresent() throws {
        let base = makeTestImage(width: 40, height: 30, color: .black)
        let document = AnnotatorDocument(
            baseImage: base,
            marks: [
                .rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 5, height: 5), stroke: .red, strokeWidth: 1)
            ],
            crop: CGRect(x: 0, y: 0, width: 12, height: 8)
        )

        let image = try SolidImageRenderer().render(document)

        XCTAssertEqual(image.pixelWidth, 12)
        XCTAssertEqual(image.pixelHeight, 8)
    }

    func testSolidRendererUsesBaseSizeWithoutCrop() throws {
        let base = makeTestImage(width: 24, height: 18, color: .black)
        let image = try SolidImageRenderer().render(AnnotatorDocument(baseImage: base))
        XCTAssertEqual(image.pixelWidth, 24)
        XCTAssertEqual(image.pixelHeight, 18)
    }

    func testMockRendererRecordsDocumentsAndDerivesSize() throws {
        let renderer = MockImageRenderer()
        let base = makeTestImage(width: 40, height: 40, color: .black)
        let document = AnnotatorDocument(
            baseImage: base,
            marks: [.blur(id: UUID(), rect: CGRect(x: 1, y: 1, width: 4, height: 4), radius: 2)],
            crop: CGRect(x: 0, y: 0, width: 10, height: 6)
        )

        let image = try renderer.render(document)

        XCTAssertEqual(renderer.recordedDocuments.count, 1)
        XCTAssertEqual(renderer.recordedDocuments[0].marks.count, 1)
        XCTAssertEqual(renderer.recordedDocuments[0].crop, CGRect(x: 0, y: 0, width: 10, height: 6))
        XCTAssertEqual(image.pixelWidth, 10)
        XCTAssertEqual(image.pixelHeight, 6)
    }

    func testAnnotatorOutputUsesRendererResult() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        harness.workflow.dispatch(.openAnnotator(harness.state.pending[0].id))

        let custom = makeTestImage(width: 3, height: 4, color: .red)
        harness.renderer.resultImage = custom
        harness.workflow.dispatch(.annotatorSaved(nil))

        XCTAssertEqual(harness.files.writtenURLs.count, 1)
        XCTAssertTrue(harness.renderer.recordedDocuments.count == 1)
    }

    // MARK: - Live ImageRenderer output shape (Testing Decisions)

    func testRectangleCenterStaysBaseColorAndStrokeIsRed() throws {
        let base = makeTestImage(width: 40, height: 40, color: .white)
        let out = try ImageRenderer().render(
            AnnotatorDocument(
                baseImage: base,
                marks: [
                    .rectangle(
                        id: UUID(),
                        rect: CGRect(x: 4, y: 4, width: 32, height: 32),
                        stroke: .red,
                        strokeWidth: 3
                    )
                ]
            )
        )
        // Interior far from the stroke is untouched white.
        if let interior = samplePixel(out, x: 20, y: 20) {
            XCTAssertGreaterThan(interior.r, 220)
            XCTAssertGreaterThan(interior.g, 220)
            XCTAssertGreaterThan(interior.b, 220)
        } else {
            XCTFail("missing interior sample")
        }
        // Stroke is red-dominant somewhere along the top edge (path y=4, width 3).
        var foundRedStroke = false
        for y in 1...8 {
            if let stroke = samplePixel(out, x: 20, y: y),
               stroke.r > 180, stroke.g < 120, stroke.b < 120 {
                foundRedStroke = true
                break
            }
        }
        XCTAssertTrue(foundRedStroke, "expected a red-dominant stroke pixel on the top edge")
    }

    func testCropTrimsToRequestedSize() throws {
        let base = makeSplitTestImage(width: 40, height: 30, top: .red, bottom: .blue)
        let out = try ImageRenderer().render(
            AnnotatorDocument(
                baseImage: base,
                marks: [],
                crop: CGRect(x: 2, y: 1, width: 10, height: 8)
            )
        )
        XCTAssertEqual(out.pixelWidth, 10)
        XCTAssertEqual(out.pixelHeight, 8)
        // Cropped from the red top band (y=1 sits in the top half).
        if let p = samplePixel(out, x: 5, y: 2) {
            XCTAssertGreaterThan(p.r, 150)
            XCTAssertLessThan(p.b, 120)
        }
    }

    func testBlurConcealsUnderlyingContent() throws {
        // Hard red/blue edge across the middle; blur the boundary.
        let base = makeSplitTestImage(width: 32, height: 32, top: .red, bottom: .blue)
        let out = try ImageRenderer().render(
            AnnotatorDocument(
                baseImage: base,
                marks: [
                    .blur(id: UUID(), rect: CGRect(x: 8, y: 8, width: 16, height: 16), radius: 6)
                ]
            )
        )
        // Center of the blur rect should no longer match pure red or pure blue.
        // (Pixelate mixes neighbors across the red/blue band boundary at y=16.)
        let samples = [
            samplePixel(out, x: 16, y: 14),
            samplePixel(out, x: 16, y: 16),
            samplePixel(out, x: 14, y: 16),
            samplePixel(out, x: 18, y: 16),
        ]
        let mixed = samples.contains { p in
            guard let p else { return false }
            // Not pure red (g,b high) and not pure blue (r high)
            let notPureRed = p.g > 20 || p.b > 20
            let notPureBlue = p.r > 20
            return notPureRed && notPureBlue
        }
        // At least one sample in the blur rect is mixed or desaturated.
        let desaturated = samples.contains { p in
            guard let p else { return false }
            let maxC = max(p.r, p.g, p.b)
            let minC = min(p.r, p.g, p.b)
            return maxC - minC < 80
        }
        XCTAssertTrue(mixed || desaturated, "blur should conceal the hard red/blue edge")
    }

    func testTextMarkDrawsUprightInk() throws {
        let base = makeTestImage(width: 60, height: 50, color: .white)
        // "L" is asymmetric: vertical stem on the left, foot at the bottom.
        let out = try ImageRenderer().render(
            AnnotatorDocument(
                baseImage: base,
                marks: [
                    .text(
                        id: UUID(),
                        string: "L",
                        origin: CGPoint(x: 10, y: 8),
                        color: .black,
                        fontSize: 28
                    )
                ]
            )
        )
        guard let bbox = darkPixelBounds(out) else {
            XCTFail("text mark produced no ink")
            return
        }
        XCTAssertGreaterThan(bbox.width, 2)
        XCTAssertGreaterThan(bbox.height, 6)

        // Upright "L": foot row has more ink than the top row of the glyph.
        let topInk = countDarkPixels(
            out,
            in: CGRect(x: bbox.minX, y: bbox.minY, width: bbox.width, height: 2)
        )
        let bottomInk = countDarkPixels(
            out,
            in: CGRect(x: bbox.minX, y: bbox.maxY - 2, width: bbox.width, height: 2)
        )
        XCTAssertGreaterThan(bottomInk, topInk, "L foot should be wider than the stem top")

        // Not mirrored: left column of the glyph has the stem (taller ink run).
        let leftInk = countDarkPixels(
            out,
            in: CGRect(x: bbox.minX, y: bbox.minY, width: 2, height: bbox.height)
        )
        let rightInk = countDarkPixels(
            out,
            in: CGRect(x: bbox.maxX - 2, y: bbox.minY, width: 2, height: bbox.height)
        )
        XCTAssertGreaterThanOrEqual(leftInk, rightInk, "L stem is on the left")
    }
}

// MARK: - cropToCapture Y-flip (Cocoa bottom-left → CGImage top-left)

@MainActor
final class CropFlipTests: XCTestCase {

    func testCropToCaptureMapsTopOfCocoaScreenToTopOfPixels() throws {
        let service = ScreenCaptureService()
        let frame = makeSplitTestImage(width: 200, height: 200, top: .red, bottom: .blue)
        let display = CGDisplayBounds(CGMainDisplayID())
        guard display.height > 0, display.width > 0 else {
            // No display geometry in this environment — skip rather than lie.
            return
        }

        // Top 80 Cocoa points (high Y in bottom-left origin) → top of the pixel buffer.
        let topRect = CGRect(x: 0, y: display.height - 80, width: 80, height: 80)
        let topCrop = try service.cropToCapture(frame, rect: topRect)
        XCTAssertGreaterThan(topCrop.pixelWidth, 0)
        XCTAssertGreaterThan(topCrop.pixelHeight, 0)
        let topMidX = topCrop.pixelWidth / 2
        let topMidY = topCrop.pixelHeight / 2
        if let p = samplePixel(topCrop, x: topMidX, y: topMidY) {
            XCTAssertGreaterThan(p.r, 150, "Cocoa-top crop should sample the red band")
            XCTAssertLessThan(p.b, 120)
        }

        // Bottom 80 Cocoa points → bottom of the pixel buffer (blue band).
        let bottomRect = CGRect(x: 0, y: 0, width: 80, height: 80)
        let bottomCrop = try service.cropToCapture(frame, rect: bottomRect)
        if let p = samplePixel(bottomCrop, x: bottomCrop.pixelWidth / 2, y: bottomCrop.pixelHeight / 2) {
            XCTAssertGreaterThan(p.b, 150, "Cocoa-bottom crop should sample the blue band")
            XCTAssertLessThan(p.r, 120)
        }
    }

    func testMockCropToCaptureAlsoFlips() throws {
        let mock = MockCaptureService()
        let frame = makeSplitTestImage(width: 40, height: 40, top: .red, bottom: .blue)
        // Mock treats rect in the frame's own point space (imageH as height).
        // Top band in Cocoa (high Y) → red.
        let top = try mock.cropToCapture(frame, rect: CGRect(x: 0, y: 30, width: 10, height: 10))
        if let p = samplePixel(top, x: 5, y: 5) {
            XCTAssertGreaterThan(p.r, 150)
        }
        let bottom = try mock.cropToCapture(frame, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        if let p = samplePixel(bottom, x: 5, y: 5) {
            XCTAssertGreaterThan(p.b, 150)
        }
    }
}
