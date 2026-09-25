import CoreGraphics
import XCTest
@testable import QuickShotCore

@MainActor
final class WorkflowAnnotatorTests: XCTestCase {

    private func makeHarnessWithAnnotator() async -> (WorkflowHarness, PendingCapture) {
        let harness = WorkflowHarness()
        harness.capture.displayImage = makeTestImage(width: 40, height: 30, color: .blue)
        harness.workflow.dispatch(.startAreaCapture)
        await harness.drain()
        harness.workflow.dispatch(.areaSelected(CGRect(x: 0, y: 0, width: 20, height: 10)))
        guard let item = harness.state.pending.first else {
            XCTFail("expected pending")
            return (harness, PendingCapture(image: makeTestImage(width: 1, height: 1, color: .black), kind: .area))
        }
        harness.workflow.dispatch(.openAnnotator(item.id))
        harness.clearEffects()
        return (harness, item)
    }

    // MARK: Copy / Save teardown

    func testAnnotatorCopiedFlattensCopiesRemovesPendingAndTearsDown() async {
        let (harness, item) = await makeHarnessWithAnnotator()
        let flat = makeTestImage(width: 20, height: 10, color: .purple)
        harness.renderer.resultImage = flat

        harness.workflow.dispatch(.annotatorCopied)

        XCTAssertEqual(harness.renderer.recordedDocuments.count, 1)
        XCTAssertTrue(harness.clipboard.images.count == 1)
        XCTAssertTrue(harness.clipboard.images[0].cgImage === flat.cgImage)
        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertNil(harness.state.annotator)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
        XCTAssertEffect(harness, matches: { $0 == .hideAnnotator })
        XCTAssertEffect(harness, matches: { $0 == .setDockVisible(false) })
    }

    func testAnnotatorSavedNilWritesToDownloadURLAndTearsDown() async {
        let (harness, item) = await makeHarnessWithAnnotator()
        let stamp = Date(timeIntervalSince1970: 1_700_000_111.001)
        harness.workflow.now = { stamp }

        harness.workflow.dispatch(.annotatorSaved(nil))

        XCTAssertEqual(harness.files.writtenURLs.count, 1)
        let url = harness.files.writtenURLs[0]
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/Downloads")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("QuickShot "))
        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertNil(harness.state.annotator)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
        XCTAssertEffect(harness, matches: { $0 == .setDockVisible(false) })
    }

    func testAnnotatorSavedURLWritesToProvidedURL() async {
        let (harness, item) = await makeHarnessWithAnnotator()
        let target = URL(fileURLWithPath: "/tmp/QuickShot-test/annotated.png")

        harness.workflow.dispatch(.annotatorSaved(target))

        XCTAssertEqual(harness.files.writtenURLs, [target])
        XCTAssertTrue(harness.state.pending.isEmpty)
        XCTAssertEqual(harness.hiddenThumbnailIDs(), [item.id])
    }

    func testRenderFailureOnCopyKeepsAnnotatorAndPending() async {
        let (harness, _) = await makeHarnessWithAnnotator()
        harness.renderer.error = MockError.boom

        harness.workflow.dispatch(.annotatorCopied)

        XCTAssertNotNil(harness.state.annotator)
        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertTrue(harness.clipboard.images.isEmpty)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    func testCopyFailureOnAnnotatorKeepsAnnotatorAndPending() async {
        let (harness, _) = await makeHarnessWithAnnotator()
        harness.clipboard.imageError = MockError.boom

        harness.workflow.dispatch(.annotatorCopied)

        XCTAssertNotNil(harness.state.annotator)
        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    func testRenderFailureOnSaveKeepsAnnotatorAndPending() async {
        let (harness, _) = await makeHarnessWithAnnotator()
        harness.renderer.error = MockError.boom

        harness.workflow.dispatch(.annotatorSaved(nil))

        XCTAssertNotNil(harness.state.annotator)
        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertTrue(harness.files.writtenURLs.isEmpty)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    func testSaveFailureOnAnnotatorKeepsAnnotatorAndPending() async {
        let (harness, _) = await makeHarnessWithAnnotator()
        harness.files.writeError = MockError.boom

        harness.workflow.dispatch(.annotatorSaved(nil))

        XCTAssertNotNil(harness.state.annotator)
        XCTAssertEqual(harness.state.pending.count, 1)
        XCTAssertEqual(harness.errorEffects().first?.1, true)
    }

    // MARK: Flatten input shape via AnnotatorEditor + MockImageRenderer

    func testFlattenReceivesMarksCropFromEditor() async {
        let (harness, _) = await makeHarnessWithAnnotator()
        let base = harness.state.annotator!.document.baseImage
        let editor = AnnotatorEditor(document: AnnotatorDocument(baseImage: base))

        editor.apply { doc in
            // Transparent-center rectangle (story 37) — stroke only in the model.
            doc.marks.append(.rectangle(
                id: UUID(),
                rect: CGRect(x: 2, y: 2, width: 12, height: 8),
                stroke: .red,
                strokeWidth: 2
            ))
        }
        editor.apply { doc in
            doc.marks.append(.blur(
                id: UUID(),
                rect: CGRect(x: 4, y: 4, width: 6, height: 4),
                radius: 3
            ))
        }
        editor.apply { doc in
            doc.crop = CGRect(x: 0, y: 0, width: 18, height: 12)
        }
        editor.sync(to: harness.workflow)

        XCTAssertEffect(harness, matches: {
            if case .updateAnnotator = $0 { return true }
            return false
        })

        harness.workflow.dispatch(.annotatorSaved(nil))

        XCTAssertEqual(harness.renderer.recordedDocuments.count, 1)
        let sent = harness.renderer.recordedDocuments[0]
        XCTAssertEqual(sent.marks.count, 2)
        if case let .rectangle(_, rect, stroke, width) = sent.marks[0] {
            XCTAssertEqual(rect, CGRect(x: 2, y: 2, width: 12, height: 8))
            XCTAssertEqual(stroke, .red)
            XCTAssertEqual(width, 2)
        } else {
            XCTFail("expected rectangle mark first")
        }
        if case let .blur(_, rect, radius) = sent.marks[1] {
            XCTAssertEqual(radius, 3)
            XCTAssertEqual(rect, CGRect(x: 4, y: 4, width: 6, height: 4))
        } else {
            XCTFail("expected blur mark second")
        }
        XCTAssertEqual(sent.crop, CGRect(x: 0, y: 0, width: 18, height: 12))
    }

    // MARK: AnnotatorEditor undo / redo (story 41)

    func testAnnotatorEditorUndoRedoRestoresMarksAndCrop() {
        let base = makeTestImage(width: 20, height: 20, color: .black)
        let editor = AnnotatorEditor(document: AnnotatorDocument(baseImage: base))

        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.canRedo)

        let rectID = UUID()
        editor.apply { doc in
            doc.marks.append(.rectangle(
                id: rectID,
                rect: CGRect(x: 1, y: 1, width: 8, height: 8),
                stroke: .blue,
                strokeWidth: 1
            ))
        }
        let blurID = UUID()
        editor.apply { doc in
            doc.marks.append(.blur(id: blurID, rect: CGRect(x: 2, y: 2, width: 4, height: 4), radius: 2))
        }
        let crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        editor.apply { doc in
            doc.crop = crop
        }

        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.document.marks.count, 2)
        XCTAssertEqual(editor.document.crop, crop)

        editor.undo()
        XCTAssertNil(editor.document.crop)
        XCTAssertEqual(editor.document.marks.count, 2)
        XCTAssertTrue(editor.canRedo)

        editor.undo()
        XCTAssertEqual(editor.document.marks.count, 1)
        XCTAssertEqual(editor.document.marks.first?.id, rectID)

        editor.undo()
        XCTAssertTrue(editor.document.marks.isEmpty)
        XCTAssertFalse(editor.canUndo)

        editor.redo()
        XCTAssertEqual(editor.document.marks.count, 1)
        editor.redo()
        XCTAssertEqual(editor.document.marks.count, 2)
        editor.redo()
        XCTAssertEqual(editor.document.crop, crop)
        XCTAssertFalse(editor.canRedo)
    }

    func testAnnotatorEditorApplyClearsRedo() {
        let base = makeTestImage(width: 10, height: 10, color: .white)
        let editor = AnnotatorEditor(document: AnnotatorDocument(baseImage: base))
        editor.apply { doc in
            doc.marks.append(.highlight(id: UUID(), rect: CGRect(x: 0, y: 0, width: 5, height: 5), color: .yellow))
        }
        editor.apply { doc in
            doc.marks.append(.arrow(id: UUID(), start: .zero, end: CGPoint(x: 4, y: 4), color: .red, width: 2))
        }
        editor.undo()
        XCTAssertTrue(editor.canRedo)

        editor.apply { doc in
            doc.marks.append(.text(id: UUID(), string: "hi", origin: .zero, color: .black, fontSize: 12))
        }

        XCTAssertFalse(editor.canRedo)
        XCTAssertEqual(editor.document.marks.count, 2)
    }

    func testAnnotatorEditorNotifiesOnChange() {
        let base = makeTestImage(width: 10, height: 10, color: .white)
        let editor = AnnotatorEditor(document: AnnotatorDocument(baseImage: base))
        var changes = 0
        editor.onDidChange = { _ in changes += 1 }

        editor.apply { $0.crop = CGRect(x: 0, y: 0, width: 5, height: 5) }
        editor.undo()
        editor.redo()

        XCTAssertEqual(changes, 3)
    }
}
