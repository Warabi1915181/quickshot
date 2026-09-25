import CoreGraphics
import XCTest
@testable import QuickShotCore

@MainActor
final class WorkflowOCRTests: XCTestCase {

    // MARK: OCR Image (menu file entry)

    func testOCRImageSuccessShowsReviewWithoutPending() async throws {
        let harness = WorkflowHarness()
        let source = makeTestImage(width: 16, height: 12, color: .green)
        let url = try writePNGToTemp(source)
        harness.ocr.result = OCRResult(text: "file text", lines: ["file text"])

        harness.workflow.dispatch(.ocrImage(url))
        await harness.drain()

        XCTAssertEqual(harness.state.ocrReview?.result.text, "file text")
        XCTAssertEqual(harness.state.ocrReview?.fromAnnotator, false)
        XCTAssertNil(harness.state.ocrReview?.sourceCaptureID)
        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEffect(harness, matches: {
            if case .showOCRReview = $0 { return true }
            return false
        })
        XCTAssertEqual(harness.ocr.calls.count, 1)
        XCTAssertEqual(harness.ocr.calls.first?.region, nil)
    }

    func testOCRImageLoadFailureShowsErrorWithoutReview() async {
        let harness = WorkflowHarness()
        let missing = URL(fileURLWithPath: "/tmp/QuickShot-test/missing-\(UUID().uuidString).png")

        harness.workflow.dispatch(.ocrImage(missing))
        await harness.drain()

        XCTAssertNil(harness.state.ocrReview)
        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.errorEffects().count, 1)
        XCTAssertEqual(harness.errorEffects().first?.1, false)
        XCTAssertTrue(harness.ocr.calls.isEmpty)
    }

    func testOCRImageOCRFailureShowsErrorWithoutReview() async throws {
        let harness = WorkflowHarness()
        let url = try writePNGToTemp(makeTestImage(width: 8, height: 8, color: .black))
        harness.ocr.error = MockError.boom

        harness.workflow.dispatch(.ocrImage(url))
        await harness.drain()

        XCTAssertNil(harness.state.ocrReview)
        XCTAssertEqual(harness.ocr.calls.count, 1)
        XCTAssertEqual(harness.errorEffects().count, 1)
        XCTAssertEqual(harness.errorEffects().first?.1, false)
    }

    // MARK: OCR from annotator

    func testOCRAnnotatorImageKeepsAnnotatorAndOpensReviewFromAnnotator() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        let item = harness.state.pending[0]
        harness.workflow.dispatch(.openAnnotator(item.id))
        harness.ocr.result = OCRResult(text: "anno text", lines: ["anno text"])

        harness.workflow.dispatch(.ocrAnnotatorImage)
        await harness.drain()

        XCTAssertNotNil(harness.state.annotator)
        XCTAssertEqual(harness.state.annotator?.captureID, item.id)
        XCTAssertEqual(harness.state.ocrReview?.result.text, "anno text")
        XCTAssertEqual(harness.state.ocrReview?.fromAnnotator, true)
        XCTAssertEqual(harness.state.ocrReview?.sourceCaptureID, item.id)
        // Source pending capture is not removed by OCR (not an image output).
        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.renderer.recordedDocuments.count, 1)
    }

    func testOCRAnnotatorImageFailureKeepsAnnotator() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        harness.workflow.dispatch(.openAnnotator(harness.state.pending[0].id))
        harness.ocr.error = MockError.boom

        harness.workflow.dispatch(.ocrAnnotatorImage)
        await harness.drain()

        XCTAssertNotNil(harness.state.annotator)
        XCTAssertNil(harness.state.ocrReview)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    // MARK: Review copy / dismiss (story 50)

    func testOCRReviewCopyCopiesTextEqualResultAndDismisses() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.ocr.result = OCRResult(text: "line one\nline two", lines: ["line one", "line two"])
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 8, height: 8)))
        await harness.drain()

        let reviewed = harness.state.ocrReview?.result.text
        XCTAssertEqual(reviewed, "line one\nline two")

        harness.workflow.dispatch(.ocrReviewCopy)

        XCTAssertEqual(harness.clipboard.texts, [reviewed].compactMap { $0 })
        XCTAssertNil(harness.state.ocrReview)
        XCTAssertEffect(harness, matches: { $0 == .hideOCRReview })
        // OCR path is not a completed image output — leave pending alone (none here).
        XCTAssertTrue(harness.state.pending.isEmpty)
    }

    func testOCRReviewCopyFromAnnotatorLeavesPendingCaptureAlone() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        let item = harness.state.pending[0]
        harness.workflow.dispatch(.openAnnotator(item.id))
        harness.ocr.result = OCRResult(text: "keep me", lines: ["keep me"])
        harness.workflow.dispatch(.ocrAnnotatorImage)
        await harness.drain()

        harness.workflow.dispatch(.ocrReviewCopy)

        XCTAssertEqual(harness.clipboard.texts, ["keep me"])
        XCTAssertNil(harness.state.ocrReview)
        XCTAssertNotNil(harness.state.annotator)
        XCTAssertEqual(harness.state.pending.map(\.id), [item.id])
    }

    func testOCRReviewDismissDoesNotTouchClipboard() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.ocr.result = OCRResult(text: "nope", lines: ["nope"])
        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()

        harness.workflow.dispatch(.ocrReviewDismiss)

        XCTAssertTrue(harness.clipboard.texts.isEmpty)
        XCTAssertNil(harness.state.ocrReview)
        XCTAssertEffect(harness, matches: { $0 == .hideOCRReview })
    }

    func testOCRReviewCopyFailureKeepsReviewOpen() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.ocr.result = OCRResult(text: "still here", lines: ["still here"])
        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()
        harness.clipboard.textError = MockError.boom

        harness.workflow.dispatch(.ocrReviewCopy)

        XCTAssertNotNil(harness.state.ocrReview)
        XCTAssertEqual(harness.state.ocrReview?.result.text, "still here")
        XCTAssertTrue(harness.clipboard.texts.isEmpty)
        XCTAssertEqual(harness.errorEffects().count, 1)
    }

    func testOCRReviewCopyAndDismissAreDistinctPaths() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 16, height: 16, color: .blue)
        harness.ocr.result = OCRResult(text: "a", lines: ["a"])
        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()
        harness.workflow.dispatch(.ocrReviewCopy)
        XCTAssertEqual(harness.clipboard.texts, ["a"])

        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()
        harness.workflow.dispatch(.ocrReviewDismiss)

        // Distinct: copy wrote clipboard once; dismiss wrote nothing extra.
        XCTAssertEqual(harness.clipboard.texts, ["a"])
        XCTAssertNil(harness.state.ocrReview)
    }
}
