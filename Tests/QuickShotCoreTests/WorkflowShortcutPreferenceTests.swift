import CoreGraphics
import XCTest
@testable import QuickShotCore

@MainActor
final class WorkflowShortcutPreferenceTests: XCTestCase {

    func testDefaultPreferencesMatchSpecStories() {
        let prefs = AppPreferences()

        XCTAssertEqual(prefs.areaShortcut, KeyBinding.areaCaptureDefault)
        XCTAssertEqual(prefs.displayShortcut, KeyBinding.displayCaptureDefault)
        XCTAssertEqual(prefs.areaShortcut, KeyBinding(keyCode: 0x15, modifiers: 0x100 | 0x200))
        XCTAssertEqual(prefs.displayShortcut, KeyBinding(keyCode: 0x14, modifiers: 0x100 | 0x200))
        XCTAssertNil(prefs.windowShortcut)
        XCTAssertNil(prefs.ocrShortcut)
        XCTAssertEqual(prefs.includePointer, false)
        XCTAssertEqual(prefs.includeWindowShadows, true)
        XCTAssertEqual(prefs.thumbnailPosition, .bottomLeading)
    }

    func testPreferencesChangedUpdatesStateWithoutRegisteringShortcuts() {
        let harness = WorkflowHarness()
        var prefs = AppPreferences()
        prefs.areaShortcut = KeyBinding(keyCode: 0x00, modifiers: 0x100 | 0x200)
        prefs.displayShortcut = KeyBinding(keyCode: 0x01, modifiers: 0x100 | 0x200)
        prefs.windowShortcut = KeyBinding(keyCode: 0x02, modifiers: 0x100)
        prefs.ocrShortcut = KeyBinding(keyCode: 0x03, modifiers: 0x100 | 0x200 | 0x800)
        prefs.thumbnailPosition = .topTrailing
        prefs.includePointer = true
        prefs.includeWindowShadows = false

        harness.workflow.dispatch(.preferencesChanged(prefs))

        XCTAssertEqual(harness.state.preferences, prefs)
        XCTAssertEqual(harness.state.preferences.areaShortcut, KeyBinding(keyCode: 0x00, modifiers: 0x100 | 0x200))
        XCTAssertEqual(harness.state.preferences.windowShortcut, KeyBinding(keyCode: 0x02, modifiers: 0x100))
        // Shell owns shortcut registration (story 7). Workflow must not touch it.
        XCTAssertTrue(harness.shortcuts.registered.isEmpty)
        XCTAssertEqual(harness.shortcuts.unregisterAllCallCount, 0)
    }

    func testPreferencesChangedDuringSelectionLeavesSelectionIntact() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 30, height: 30, color: .blue)
        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        let session = harness.state.selection

        var prefs = AppPreferences()
        prefs.includePointer = true
        harness.workflow.dispatch(.preferencesChanged(prefs))

        XCTAssertEqual(harness.state.selection, session)
        XCTAssertEqual(harness.capture.captureDisplayCallCount, 1)
        // Pointer pref applies to the next capture, not the active freeze.
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 5, height: 5)))
        XCTAssertEqual(harness.state.pending.count, 1)
    }

    func testThumbnailFlowNeverEmitsAnnotatorOrDockEffects() async {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 20, height: 20, color: .blue)

        harness.workflow.dispatch(.startDisplayCapture)
        await harness.drain()
        let id = harness.state.pending[0].id
        harness.workflow.dispatch(.copy(id))

        // Story 23 at workflow level: no effect asks for key window / annotator
        // during a pure thumbnail flow. `WorkflowEffect` has no key-window case;
        // assert annotator surfaces stay out of the stream.
        for effect in harness.effects {
            switch effect {
            case .showAnnotator, .setDockVisible(true):
                XCTFail("thumbnail flow must not activate annotator/dock focus surface: \(effect)")
            default:
                break
            }
        }
    }

    func testOCRReviewKeyboardContractIsDistinctWorkflowPaths() async {
        // UI maps Return → ocrReviewCopy and Escape → ocrReviewDismiss (story 50).
        // Workflow level: the two events must stay separate observable paths.
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 16, height: 16, color: .blue)
        harness.ocr.result = OCRResult(text: "kb", lines: ["kb"])

        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()
        let copyEffectsBefore = harness.effects.count
        harness.workflow.dispatch(.ocrReviewCopy)

        XCTAssertEqual(harness.clipboard.texts, ["kb"])
        XCTAssertNil(harness.state.ocrReview)
        XCTAssertGreaterThan(harness.effects.count, copyEffectsBefore)

        let textsAfterCopy = harness.clipboard.texts
        harness.workflow.dispatch(.startOCRSelection)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 4, height: 4)))
        await harness.drain()
        harness.workflow.dispatch(.ocrReviewDismiss)

        XCTAssertEqual(harness.clipboard.texts, textsAfterCopy)
        XCTAssertNil(harness.state.ocrReview)
    }

    func testShortcutConflictIsShellOwnedWorkflowDoesNotRegister() {
        // Conflict handling is adapter/shell territory. Document that dispatching
        // preference changes never calls register (which is where conflicts throw).
        let harness = WorkflowHarness()
        harness.shortcuts.registerError = WorkflowError.shortcutConflict("taken")

        harness.workflow.dispatch(.preferencesChanged(AppPreferences()))

        XCTAssertTrue(harness.shortcuts.registered.isEmpty)
        XCTAssertTrue(harness.effects.isEmpty)
    }
}
