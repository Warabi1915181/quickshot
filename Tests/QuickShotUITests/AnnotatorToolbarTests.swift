import AppKit
import XCTest
@testable import QuickShot

@MainActor
final class AnnotatorToolbarTests: XCTestCase {
    func testToolSegmentsShowOnlyTheirIcon() throws {
        _ = NSApplication.shared
        let toolbar = AnnotatorToolbar(frame: NSRect(x: 0, y: 0, width: 1100, height: 52))
        let control = try XCTUnwrap(findToolControl(in: toolbar))
        XCTAssertEqual(control.segmentCount, 7)
        for index in 0..<control.segmentCount {
            XCTAssertNotNil(control.image(forSegment: index))
            XCTAssertEqual(control.label(forSegment: index) ?? "", "",
                           "Tool names must not render beside icons in narrow segments")
            XCTAssertFalse(control.image(forSegment: index)?.accessibilityDescription?.isEmpty ?? true)
            XCTAssertEqual(control.toolTip(forSegment: index), control.image(forSegment: index)?.accessibilityDescription)
        }
    }

    func testTextSizeControlRoutesChangesAndRestoresStrokeWidth() throws {
        _ = NSApplication.shared
        let toolbar = AnnotatorToolbar(frame: .zero)
        let slider = try XCTUnwrap(findSlider(in: toolbar))
        var fontSize: Double?
        var strokeWidth: Double?
        toolbar.onChangeFontSize = { fontSize = $0 }
        toolbar.onChangeStrokeWidth = { strokeWidth = $0 }
        toolbar.setState(selectedTool: .text, color: .red, strokeWidth: 4,
                         fontSize: 36, canUndo: false, canRedo: false, cropPending: false)
        XCTAssertEqual(slider.doubleValue, 36)
        XCTAssertEqual(slider.minValue, 8)
        XCTAssertEqual(slider.maxValue, 96)
        XCTAssertEqual(slider.accessibilityLabel(), "Font size")
        slider.doubleValue = 47.6
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(fontSize, 48)
        XCTAssertNil(strokeWidth)

        toolbar.setState(selectedTool: .arrow, color: .red, strokeWidth: 4,
                         fontSize: 48, canUndo: false, canRedo: false, cropPending: false)
        XCTAssertEqual(slider.doubleValue, 4)
        XCTAssertEqual(slider.maxValue, 24)
        XCTAssertEqual(slider.accessibilityLabel(), "Stroke width")
        slider.doubleValue = 6
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(strokeWidth, 6)
        XCTAssertEqual(fontSize, 48)
    }

    func testTextEditorResizesAndCommitsChosenFontSize() throws {
        _ = NSApplication.shared
        let canvas = AnnotatorCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.activeTool = .text
        canvas.setZoom(0.5)
        canvas.fontSize = 36
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(field.font?.pointSize, 18)
        field.stringValue = "Large text"
        canvas.fontSize = 96
        XCTAssertEqual(field.font?.pointSize, 48)
        XCTAssertGreaterThan(field.frame.height, 48)
        canvas.onApply = { transform in transform(&canvas.document) }
        canvas.commitTextEditing()
        guard case let .text(_, string, _, _, size) = canvas.document.marks.first else {
            return XCTFail("Expected committed text mark")
        }
        XCTAssertEqual(string, "Large text")
        XCTAssertEqual(size, 96)
    }

    func testClickCommittedTextReopensAndReplacesSameMark() throws {
        _ = NSApplication.shared
        let canvas = AnnotatorCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.activeTool = .text
        canvas.onApply = { transform in transform(&canvas.document) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 200, y: 150),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let first = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        first.stringValue = "Original"
        canvas.commitTextEditing()
        canvas.mouseDown(with: event)
        let reopened = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(reopened.stringValue, "Original")
        reopened.stringValue = "Edited"
        canvas.fontSize = 42
        canvas.commitTextEditing()
        XCTAssertEqual(canvas.document.marks.count, 1)
        guard case let .text(_, string, _, _, size) = canvas.document.marks.first else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(string, "Edited")
        XCTAssertEqual(size, 42)
    }

    func testSizeNumberUpdatesForStepperSliderAndTyping() throws {
        _ = NSApplication.shared
        let toolbar = AnnotatorToolbar(frame: .zero)
        toolbar.setState(selectedTool: .text, color: .red, strokeWidth: 4,
                         fontSize: 18, canUndo: false, canRedo: false, cropPending: false)
        let views = descendants(of: toolbar)
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))
        let stepper = try XCTUnwrap(views.compactMap { $0 as? NSStepper }.first)
        let slider = try XCTUnwrap(findSlider(in: toolbar))
        var size: Double?
        toolbar.onChangeFontSize = { size = $0 }
        stepper.doubleValue = 19
        stepper.sendAction(stepper.action, to: stepper.target)
        XCTAssertEqual(field.stringValue, "19")
        XCTAssertEqual(size, 19)
        slider.doubleValue = 40
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(field.stringValue, "40")
        XCTAssertEqual(stepper.doubleValue, 40)
        field.stringValue = "64"
        toolbar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(size, 64)
        XCTAssertEqual(slider.doubleValue, 64)
        XCTAssertEqual(stepper.doubleValue, 64)
        field.stringValue = "invalid"
        toolbar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "64")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func findSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        return view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
    }

    private func findToolControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.findToolControl(in: $0) }.first
    }
}
