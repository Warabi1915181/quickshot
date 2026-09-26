import AppKit
import QuickShotCore

/// Annotator window. Keys reach `onKeyEvent` before the first responder.
final class AnnotatorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var onKeyEvent: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleTextEditingShortcut(event) { return }
        if onKeyEvent?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleTextEditingShortcut(event) { return true }
        if onKeyEvent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    /// Accessory apps have no Edit menu to dispatch the usual field-editor commands.
    private func handleTextEditingShortcut(_ event: NSEvent) -> Bool {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor,
              event.modifierFlags.intersection([.command, .control, .option]) == .command else {
            return false
        }
        let action: Selector
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": action = #selector(NSText.selectAll(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "z":
            action = NSSelectorFromString(event.modifierFlags.contains(.shift) ? "redo:" : "undo:")
        default: return false
        }
        return editor.tryToPerform(action, with: self)
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
