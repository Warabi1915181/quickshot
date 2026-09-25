import CoreGraphics
import XCTest
@testable import QuickShotCore

@MainActor
final class WorkflowPendingActionTests: XCTestCase {

    private func makeHarnessWithOnePending(
        kind: CaptureKind = .area
    ) async -> (WorkflowHarness, PendingCapture) {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        switch kind {
        case .display:
            harness.workflow.dispatch(.startDisplayCapture)
            await harness.drain()
        case .area, .window:
            harness.workflow.dispatch(.startAreaCapture)
            await harness.drain()
            if kind == .window {
                harness.workflow.dispatch(.selectionModeChanged(.window))
                harness.workflow.dispatch(.windowSelected(9))
                await harness.drain()
            } else {
                harness.workflow.dispatch(.areaSelected(CGRect(x: 5, y: 5, width: 10, height: 10)))
            }
        }

        guard let item = harness.state.pending.first else {
            XCTFail("expected pending capture")
            return (harness, PendingCapture(image: makeTestImage(width: 1, height: 1, color: .black), kind: kind))
        }
        harness.clearEffects()
        return (harness, item)
    }

    // MARK: Copy

    func testCopySuccessRemovesItemHidesThumbnailAndWritesClipboard() async {
        let (harness, item) = await makeHarnessWithOnePending()

        harness.workflow.dispatch(.copy(item.id))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
        XCTAssertEqual(harness.clipboard.images.count, 1)
        XCTAssertTrue(harness.clipboard.images[0].cgImage === item.image.cgImage)
        XCTAssertTrue(harness.files.writtenURLs.isEmpty)
    }

    func testCopyFailureKeepsItemAndReportsAvailable() async {
        let (harness, item) = await makeHarnessWithOnePending()
        harness.clipboard.imageError = MockError.boom

        harness.workflow.dispatch(.copy(item.id))

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.state.pending.first?.id, item.id)
        XCTAssertTrue(harness.hiddenThumbnailIDs().isEmpty)
        XCTAssertEqual(harness.errorEffects().count, 1)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
        if case .copyFailed? = harness.errorEffects().first?.0 {} else {
            XCTFail("expected copyFailed")
        }
    }

    // MARK: Save

    func testSaveSuccessWritesPNGRemovesItem() async {
        let (harness, item) = await makeHarnessWithOnePending()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        harness.workflow.now = { stamp }

        harness.workflow.dispatch(.save(item.id))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.files.writtenURLs.count, 1)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
        XCTAssertTrue(harness.clipboard.images.isEmpty)
        let name = harness.files.writtenURLs[0].lastPathComponent
        XCTAssertTrue(name.hasPrefix("QuickShot "))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    func testSaveFailureKeepsItem() async {
        let (harness, item) = await makeHarnessWithOnePending()
        harness.files.writeError = MockError.boom

        harness.workflow.dispatch(.save(item.id))

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.files.writtenURLs.count, 0)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
        if case .saveFailed? = harness.errorEffects().first?.0 {} else {
            XCTFail("expected saveFailed")
        }
    }

    func testSaveAsSuccessUsesProvidedURL() async {
        let (harness, item) = await makeHarnessWithOnePending()
        let target = URL(fileURLWithPath: "/tmp/QuickShot-test/custom-name.png")

        harness.workflow.dispatch(.saveAs(item.id, target))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.files.writtenURLs, [target])
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
    }

    func testSaveAsFailureKeepsItem() async {
        let (harness, item) = await makeHarnessWithOnePending()
        harness.files.writeError = MockError.boom
        let target = URL(fileURLWithPath: "/tmp/QuickShot-test/custom-name.png")

        harness.workflow.dispatch(.saveAs(item.id, target))

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertTrue(harness.files.writtenURLs.isEmpty)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    func testRapidTwoSavesProduceDistinctURLs() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .red)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000.5)
        harness.workflow.now = { stamp }

        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        XCTAssertEqual(harness.state.pending.count, 2)

        let firstID = harness.state.pending[0].id
        let secondID = harness.state.pending[1].id
        harness.workflow.dispatch(.save(firstID))
        harness.workflow.dispatch(.save(secondID))

        XCTAssertEqual(harness.files.writtenURLs.count, 2)
        XCTAssertNotEqual(harness.files.writtenURLs[0], harness.files.writtenURLs[1])
        XCTAssertTrue(harness.state.pending.isEmpty)
    }

    // MARK: Discard

    func testDiscardRemovesItemWithoutFileOrClipboardCalls() async {
        let (harness, item) = await makeHarnessWithOnePending()

        harness.workflow.dispatch(.discard(item.id))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
        XCTAssertTrue(harness.files.writtenURLs.isEmpty)
        XCTAssertTrue(harness.clipboard.images.isEmpty)
        XCTAssertTrue(harness.clipboard.texts.isEmpty)
    }

    // MARK: Drag

    func testDragCompletedRemovesItem() async {
        let (harness, item) = await makeHarnessWithOnePending()

        harness.workflow.dispatch(.dragCompleted(item.id))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
    }

    func testDragFailedKeepsItemAndReportsAvailable() async {
        let (harness, item) = await makeHarnessWithOnePending()

        harness.workflow.dispatch(.dragFailed(item.id))

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.errorEffects().first?.0, .dragFailed)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    // MARK: Annotator open / close (pending must survive)

    func testOpenAnnotatorKeepsPendingAndShowsAnnotatorWithDock() async {
        let (harness, item) = await makeHarnessWithOnePending()

        harness.workflow.dispatch(.openAnnotator(item.id))

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.state.annotator?.captureID, item.id)
        XCTAssertTrue(harness.state.annotator?.document.marks.isEmpty ?? false)
        XCTAssertEffect(harness, matches: {
            if case .showAnnotator = $0 { return true }
            return false
        })
        XCTAssertEffect(harness, matches: { $0 == .setDockVisible(true) })
        // Thumbnail stays visible under the annotator (story 34 return path).
        XCTAssertTrue(harness.hiddenThumbnailIDs().isEmpty)
    }

    func testCloseAnnotatorWithoutOutputKeepsPendingAndHidesDock() async {
        let (harness, item) = await makeHarnessWithOnePending()
        harness.workflow.dispatch(.openAnnotator(item.id))
        harness.clearEffects()

        harness.workflow.dispatch(.closeAnnotatorWithoutOutput)

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.state.pending.first?.id, item.id)
        XCTAssertNil(harness.state.annotator)
        XCTAssertEffect(harness, matches: { $0 == .hideAnnotator })
        XCTAssertEffect(harness, matches: { $0 == .setDockVisible(false) })
        XCTAssertTrue(harness.hiddenThumbnailIDs().isEmpty)
    }

    // MARK: Missing ids

    func testCopyMissingIdReportsNoActiveCapture() {
        let harness = WorkflowHarness()
        harness.workflow.dispatch(.copy(UUID()))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.errorEffects().first?.0, .noActiveCapture)
        XCTAssertEqual(harness.errorEffects().first?.1, false)
    }

    func testSaveMissingIdReportsNoActiveCapture() {
        let harness = WorkflowHarness()
        harness.workflow.dispatch(.save(UUID()))

        XCTAssertEqual(harness.errorEffects().first?.0, .noActiveCapture)
        XCTAssertTrue(harness.files.writtenURLs.isEmpty)
    }

    func testDiscardMissingIdIsNoOp() {
        let harness = WorkflowHarness()
        harness.workflow.dispatch(.discard(UUID()))

        XCTAssertTrue(harness.effects.isEmpty)
        XCTAssertTrue(harness.state.pending.isEmpty)
    }

    func testOpenAnnotatorMissingIdReportsNoActiveCapture() {
        let harness = WorkflowHarness()
        harness.workflow.dispatch(.openAnnotator(UUID()))

        XCTAssertNil(harness.state.annotator)
        XCTAssertEqual(harness.errorEffects().first?.0, .noActiveCapture)
    }

    // MARK: Persistence / process exit (story 53)

    func testWorkflowHoldsNoDiskWritesExceptSavePaths() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)
        harness.ocr.result = OCRResult(text: "t", lines: ["t"])

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 5, height: 5)))
        let pendingID = harness.state.pending[0].id

        harness.workflow.dispatch(.openAnnotator(pendingID))
        harness.workflow.dispatch(.closeAnnotatorWithoutOutput)
        harness.workflow.dispatch(.copy(pendingID))
        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        harness.workflow.dispatch(.discard(harness.state.pending[0].id))
        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()
        harness.workflow.dispatch(.ocrReviewDismiss)
        harness.workflow.dispatch(.selectionCancelled)

        XCTAssertEqual(
            harness.files.writtenURLs.count,
            0,
            "workflow must not write pending state to disk outside save/saveAs"
        )

        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        harness.workflow.dispatch(.save(harness.state.pending[0].id))
        XCTAssertEqual(harness.files.writtenURLs.count, 1)
    }

    // MARK: Thumbnail focus contract (story 23)

    func testThumbnailFlowEmitsNoShowAnnotatorUnlessOpenAnnotator() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 5, height: 5)))
        let id = harness.state.pending[0].id
        harness.workflow.dispatch(.copy(id))

        // Workflow has no key-window effect at all; thumbnail actions must not
        // pull up the annotator or otherwise claim focus surfaces.
        XCTAssertNoEffect(harness, matches: {
            if case .showAnnotator = $0 { return true }
            return false
        })
        XCTAssertNoEffect(harness, matches: { $0 == .setDockVisible(true) })
    }
}
