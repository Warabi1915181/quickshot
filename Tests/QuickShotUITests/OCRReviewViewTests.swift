import AppKit
import QuickShotCore
import XCTest
@testable import QuickShot

@MainActor
final class OCRReviewViewTests: XCTestCase {
    func testRecognizedTextHasVisibleGlyphs() {
        assertVisibleText("Recognized text\nSecond line", expected: "Recognized text\nSecond line")
    }

    func testEmptyResultHasVisiblePlaceholder() {
        assertVisibleText("", expected: "(No text found)")
    }

    private func assertVisibleText(_ text: String, expected: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        _ = NSApplication.shared
        let view = OCRReviewView(frame: NSRect(x: 0, y: 0, width: 392, height: 248))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.configure(with: OCRReviewState(result: OCRResult(text: text, lines: text.components(separatedBy: "\n")), fromAnnotator: false))
        view.layoutSubtreeIfNeeded()
        let scrollView = view.subviews.compactMap { $0 as? NSScrollView }.first!
        let textView = scrollView.documentView as! NSTextView
        XCTAssertEqual(textView.string, expected, file: file, line: line)
        XCTAssertGreaterThan(textView.bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(textView.bounds.height, 0, file: file, line: line)
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            XCTFail("Missing text layout system", file: file, line: line)
            return
        }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        XCTAssertTrue(textView.visibleRect.intersects(bounds), "Text glyphs must intersect visible preview", file: file, line: line)
    }
}
