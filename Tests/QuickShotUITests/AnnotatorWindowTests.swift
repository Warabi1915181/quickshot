import AppKit
import XCTest
@testable import QuickShot

@MainActor
final class AnnotatorWindowTests: XCTestCase {
    func testClipboardShortcutsReachFocusedTextEditor() throws {
        _ = NSApplication.shared
        let window = AnnotatorWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = ClipboardEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        editor.isFieldEditor = true
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        window.onKeyEvent = { _ in XCTFail("Textbox command reached annotation handler"); return true }
        for key in ["c", "v", "x"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(editor.commands, ["copy", "paste", "cut"])
    }

    func testCommandASelectsAllTextBeforeAnnotationShortcuts() throws {
        _ = NSApplication.shared
        let window = AnnotatorWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        editor.isFieldEditor = true
        editor.string = "Annotation text"
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        var annotationShortcutCalled = false
        window.onKeyEvent = { _ in annotationShortcutCalled = true; return true }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 15))
        XCTAssertFalse(annotationShortcutCalled)
    }
}

@MainActor
private final class ClipboardEditor: NSTextView {
    var commands: [String] = []
    override func copy(_ sender: Any?) { commands.append("copy") }
    override func paste(_ sender: Any?) { commands.append("paste") }
    override func cut(_ sender: Any?) { commands.append("cut") }
}
