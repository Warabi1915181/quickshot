import CoreGraphics
import XCTest
@testable import QuickShotCore

@MainActor
final class WorkflowCaptureTests: XCTestCase {

    // MARK: Area

    func testAreaCaptureSuccessCreatesPendingThumbnailAndEndsSelection() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()

        XCTAssertNotNil(harness.state.selection)
        XCTAssertEqual(harness.state.selection?.mode, .area)
        XCTAssertEffect(harness, matches: {
            if case .beginSelection = $0 { return true }
            return false
        })

        harness.workflow.dispatch(.areaSelected(CGRect(x: 5, y: 5, width: 10, height: 10)))

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.state.pending.first?.kind, .area)
        XCTAssertEqual(harness.state.pending.first?.image.pixelWidth, 10)
        XCTAssertEqual(harness.state.pending.first?.image.pixelHeight, 10)
        XCTAssertNil(harness.state.selection)
        XCTAssertEqual(harness.thumbnailShownIDs().count, 1)
        XCTAssertEffect(harness, matches: { $0 == .endSelection })
        XCTAssertFalse(harness.state.needsCapturePermission)
    }

    func testAreaCaptureUsesIncludePointerPreference() async {
        let harness = WorkflowHarness()
        var prefs = AppPreferences()
        prefs.includePointer = true
        harness.workflow.dispatch(.preferencesChanged(prefs))
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .black)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()

        XCTAssertEqual(harness.capture.lastIncludePointer, true)
        XCTAssertEqual(harness.capture.captureDisplayCallCount, 1)
    }

    // MARK: Mode switch (W / O)

    func testSelectionModeChangedToWindowThenWindowSelectedCapturesWindow() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .black)
        harness.capture.windowImage = makeTestImage(width: 20, height: 16, color: .green)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.selectionModeChanged(.window))
        XCTAssertEqual(harness.state.selection?.mode, .window)

        harness.workflow.dispatch(.windowSelected(42))
        await harness.drain()

        XCTAssertEqual(harness.capture.windowCaptureCalls.count, 1)
        XCTAssertEqual(harness.capture.windowCaptureCalls.first?.id, 42)
        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.state.pending.first?.kind, .window)
        XCTAssertEqual(harness.state.pending.first?.image.pixelWidth, 20)
        XCTAssertNil(harness.state.selection)
        XCTAssertEffect(harness, matches: { $0 == .endSelection })
    }

    func testWindowCapturePassesShadowAndPointerPreferences() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .black)

        var prefs = AppPreferences()
        prefs.includeWindowShadows = false
        prefs.includePointer = true
        harness.workflow.dispatch(.preferencesChanged(prefs))

        harness.workflow.dispatch(.startWindowCapture)
        await harness.drain()
        harness.workflow.dispatch(.windowSelected(7))
        await harness.drain()

        let call = harness.capture.windowCaptureCalls.first
        XCTAssertEqual(call?.id, 7)
        XCTAssertEqual(call?.includeShadow, false)
        XCTAssertEqual(call?.includePointer, true)
    }

    func testModeSwitchDoesNotRecapture() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.selectionModeChanged(.window))
        harness.workflow.dispatch(.selectionModeChanged(.ocrRegion))
        harness.workflow.dispatch(.selectionModeChanged(.area))

        XCTAssertEqual(harness.capture.captureDisplayCallCount, 1)
        XCTAssertEqual(harness.state.selection?.mode, .area)
    }

    func testAreaSelectedInWindowModeCreatesNoCapture() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.selectionModeChanged(.window))
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 10, height: 10)))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertNil(harness.state.selection)
        XCTAssertEffect(harness, matches: { $0 == .endSelection })
    }

    // MARK: Cancel

    func testSelectionCancelledCreatesNothing() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.selectionCancelled)

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertNil(harness.state.selection)
        XCTAssertEffect(harness, matches: { $0 == .endSelection })
        XCTAssertTrue(harness.thumbnailShownIDs().isEmpty)
        XCTAssertEqual(harness.files.writtenURLs.count, 0)
        XCTAssertTrue(harness.clipboard.images.isEmpty)
    }

    // MARK: Display

    func testDisplayCaptureCreatesPendingWithoutSelection() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 30, color: .orange)

        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()

        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.state.pending.first?.kind, .display)
        XCTAssertNil(harness.state.selection)
        XCTAssertNoEffect(harness, matches: {
            if case .beginSelection = $0 { return true }
            return false
        })
        XCTAssertEqual(harness.thumbnailShownIDs().count, 1)
    }

    // MARK: OCR region selection

    func testOCRSelectionShowsReviewWithoutThumbnailOrPending() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)
        harness.ocr.result = OCRResult(text: "recognized", lines: ["recognized"])

        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        XCTAssertEqual(harness.state.selection?.mode, .ocrRegion)

        harness.workflow.dispatch(.areaSelected(CGRect(x: 4, y: 4, width: 12, height: 8)))
        await harness.drain()

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertTrue(harness.thumbnailShownIDs().isEmpty)
        XCTAssertEqual(harness.state.ocrReview?.result.text, "recognized")
        XCTAssertEqual(harness.state.ocrReview?.fromAnnotator, false)
        XCTAssertNil(harness.state.ocrReview?.sourceCaptureID)
        XCTAssertNil(harness.state.selection)
        XCTAssertEffect(harness, matches: {
            if case .showOCRReview = $0 { return true }
            return false
        })
        XCTAssertEqual(harness.ocr.calls.count, 1)
        XCTAssertEqual(harness.ocr.calls.first?.region, nil)
        XCTAssertEqual(harness.ocr.calls.first?.image.pixelWidth, 12)
        XCTAssertEqual(harness.ocr.calls.first?.image.pixelHeight, 8)
    }

    func testOCRSelectionFailureShowsErrorAndNoPending() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)
        harness.ocr.error = MockError.boom

        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 8, height: 8)))
        await harness.drain()

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertNil(harness.state.ocrReview)
        XCTAssertNoEffect(harness, matches: {
            if case .showThumbnail = $0 { return true }
            return false
        })
        XCTAssertEqual(harness.errorEffects().count, 1)
        XCTAssertEqual(harness.errorEffects().first?.1, false)
    }

    // MARK: Permission gate

    private func assertPermissionDenied(
        _ event: WorkflowEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let harness = WorkflowHarness()
        harness.capture.permission = false

        harness.workflow.dispatch(event)
        await harness.drain()

        XCTAssertTrue(harness.state.needsCapturePermission, file: file, line: line)
        XCTAssertEffect(harness, matches: { $0 == .requestCapturePermission }, file: file, line: line)
        XCTAssertTrue(harness.state.pending.isEmpty, file: file, line: line)
        XCTAssertNil(harness.state.selection, file: file, line: line)
        XCTAssertEqual(harness.capture.captureDisplayCallCount, 0, file: file, line: line)
    }

    func testPermissionDeniedOnAreaCapture() async {
        await assertPermissionDenied(.startAreaCapture)
    }

    func testPermissionDeniedOnWindowCapture() async {
        await assertPermissionDenied(.startWindowCapture)
    }

    func testPermissionDeniedOnDisplayCapture() async {
        await assertPermissionDenied(.startDisplayCapture)
    }

    func testPermissionDeniedOnOCRSelection() async {
        await assertPermissionDenied(.startOCRSelection)
    }

    func testPermissionDeniedEventSurfacesGuidanceError() {
        let harness = WorkflowHarness()
        harness.workflow.dispatch(.permissionDenied)

        XCTAssertTrue(harness.state.needsCapturePermission)
        XCTAssertEqual(harness.errorEffects().first?.0, .capturePermissionDenied)
    }

    // MARK: Multiple pending

    func testMultipleAreaCapturesStackTwoPendingItems() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 10, height: 10)))

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 10, y: 10, width: 8, height: 8)))

        XCTAssertEqual(harness.state.pending.count, 2)
        XCTAssertEqual(harness.state.pending.map(\.kind), [.area, .area])
        XCTAssertEqual(harness.state.pending[0].image.pixelWidth, 10)
        XCTAssertEqual(harness.state.pending[1].image.pixelWidth, 8)
        XCTAssertEqual(harness.thumbnailShownIDs().count, 2)
        // Newest last
        XCTAssertEqual(harness.state.pending.last?.id, harness.thumbnailShownIDs().last)
    }

    // MARK: Crop failure

    func testAreaSelectedCropFailureShowsErrorAndClearsSelection() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 40, color: .blue)

        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.capture.cropError = MockError.boom
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 10, height: 10)))

        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertNil(harness.state.selection)
        XCTAssertEqual(harness.errorEffects().first?.1, false)
        XCTAssertEffect(harness, matches: { $0 == .endSelection })
    }
}
