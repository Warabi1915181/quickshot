import AppKit
import QuickShotCore

/// Annotator window. Keys reach `onKeyEvent` before the first responder.
final class AnnotatorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var onKeyEvent: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyEvent?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEvent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Color bridge

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent),
            alpha: Double(rgb.alphaComponent)
        )
    }
}
