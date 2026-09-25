import AppKit
import QuickShotCore

// MARK: - Glyph helpers

enum ShortcutGlyph {
    /// Carbon modifier bits used by `KeyBinding` / `CarbonShortcutService`.
    static let cmdKey: UInt32 = 0x100
    static let shiftKey: UInt32 = 0x200
    static let optionKey: UInt32 = 0x800
    static let controlKey: UInt32 = 0x1000

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return result
    }

    static func string(for binding: KeyBinding) -> String {
        var text = ""
        if binding.modifiers & controlKey != 0 { text += "⌃" }
        if binding.modifiers & optionKey != 0 { text += "⌥" }
        if binding.modifiers & shiftKey != 0 { text += "⇧" }
        if binding.modifiers & cmdKey != 0 { text += "⌘" }
        text += keyName(for: binding.keyCode)
        return text
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let name = keyNames[Int(keyCode)] { return name }
        return "key\(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
        0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
        0x30: "⇥", 0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "⎋",
        0x72: "Help", 0x73: "↖", 0x74: "⇞", 0x75: "⌦", 0x76: "F4", 0x77: "End",
        0x78: "F2", 0x79: "F3", 0x7A: "F1", 0x7B: "F5", 0x7C: "F6", 0x7D: "F7",
        0x7E: "↑", 0x7F: "F8", 0x6C: "↩",
        0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x4A: "F21",
        0x4B: "F22", 0x4C: "F23", 0x4D: "F24", 0x4E: "F25",
        0x90: "F26", 0x91: "F27", 0x92: "F28", 0x93: "F29",
        0x94: "F30", 0x95: "F31", 0x96: "F32",
        0x63: "Fn",
    ]
}

// MARK: - ShortcutRecorderView

/// Captures keyDown and shows `⌘⇧4`-style glyphs. Lives here to keep file count down.
@MainActor
final class ShortcutRecorderView: NSView {
    var onChange: ((KeyBinding?) -> Void)?
    /// When true, Backspace clears the binding.
    var allowsClear = false

    var binding: KeyBinding? {
        didSet { needsDisplay = true; toolTip = binding.map(ShortcutGlyph.string(for:)) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -2, dy: -2) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels recording without changing the binding.
        if event.keyCode == 0x35 {
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }
        // Backspace clears optional bindings.
        if event.keyCode == 0x33, allowsClear {
            binding = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }
        // Ignore bare modifier presses and modifier-only "keys".
        let mods = ShortcutGlyph.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else {
            NSSound.beep()
            return
        }
        // Skip pure modifier keyCodes (Command/Shift/Option/Control/R*).
        let code = Int(event.keyCode)
        if (0x37...0x3E).contains(code) || code == 0x3F {
            return
        }
        let next = KeyBinding(keyCode: UInt32(event.keyCode), modifiers: mods)
        binding = next
        onChange?(next)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While first responder, swallow key equivalents so they become the binding.
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (window?.firstResponder === self ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = window?.firstResponder === self ? 2 : 1
        path.stroke()

        let text: String
        if let binding {
            text = ShortcutGlyph.string(for: binding)
        } else if window?.firstRecorder === self {
            text = "Type shortcut…"
        } else {
            text = allowsClear ? "None" : "Click to record"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular)),
            .foregroundColor: binding == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}

private extension NSWindow {
    var firstRecorder: ShortcutRecorderView? { firstResponder as? ShortcutRecorderView }
}

// MARK: - SettingsWindowController

/// Settings form: shortcuts, thumbnail position, capture toggles, login item (stories 2, 7, 15–18, 21).
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Return true after a successful `preferencesChanged` + rebind + save.
    /// On false, fields revert to `committed`.
    var onApply: ((AppPreferences) -> Bool)?
    var onLoginItemChanged: ((Bool) -> Void)?

    private var committed: AppPreferences

    private let areaRecorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    private let displayRecorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    private let windowRecorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    private let ocrRecorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    private let windowClear = NSButton(title: "Clear", target: nil, action: nil)
    private let ocrClear = NSButton(title: "Clear", target: nil, action: nil)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shadowsCheckbox = NSButton(checkboxWithTitle: "Include window shadows", target: nil, action: nil)
    private let pointerCheckbox = NSButton(checkboxWithTitle: "Include pointer", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    init(preferences: AppPreferences) {
        self.committed = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickShot Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        buildUI()
        restore(preferences)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        restore(committed)
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Reload fields (used after a failed apply, or external prefs change).
    func restore(_ prefs: AppPreferences) {
        committed = prefs
        areaRecorder.binding = prefs.areaShortcut
        displayRecorder.binding = prefs.displayShortcut
        windowRecorder.binding = prefs.windowShortcut
        ocrRecorder.binding = prefs.ocrShortcut
        windowRecorder.allowsClear = true
        ocrRecorder.allowsClear = true
        windowClear.isEnabled = prefs.windowShortcut != nil
        ocrClear.isEnabled = prefs.ocrShortcut != nil

        positionPopup.removeAllItems()
        for position in [ThumbnailPosition.bottomLeading, .bottomTrailing, .topLeading, .topTrailing] {
            positionPopup.addItem(withTitle: Self.title(for: position))
            positionPopup.lastItem?.representedObject = position.rawValue
        }
        positionPopup.selectItem(withTitle: Self.title(for: prefs.thumbnailPosition))

        shadowsCheckbox.state = prefs.includeWindowShadows ? .on : .off
        pointerCheckbox.state = prefs.includePointer ? .on : .off
    }

    func setLoginEnabled(_ enabled: Bool) {
        loginCheckbox.state = enabled ? .on : .off
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        areaRecorder.allowsClear = false
        displayRecorder.allowsClear = false
        windowRecorder.allowsClear = true
        ocrRecorder.allowsClear = true

        windowClear.target = self
        windowClear.action = #selector(clearWindow)
        ocrClear.target = self
        ocrClear.action = #selector(clearOCR)

        windowRecorder.onChange = { [weak self] binding in
            self?.windowClear.isEnabled = binding != nil
        }
        ocrRecorder.onChange = { [weak self] binding in
            self?.ocrClear.isEnabled = binding != nil
        }

        shadowsCheckbox.target = self
        shadowsCheckbox.action = #selector(checkboxChanged)
        pointerCheckbox.target = self
        pointerCheckbox.action = #selector(checkboxChanged)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)

        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let windowRow = NSStackView(views: [windowRecorder, windowClear])
        windowRow.orientation = .horizontal
        windowRow.spacing = 8
        let ocrRow = NSStackView(views: [ocrRecorder, ocrClear])
        ocrRow.orientation = .horizontal
        ocrRow.spacing = 8

        let grid = NSGridView(views: [
            [label("Capture Area"), areaRecorder],
            [label("Capture Display"), displayRecorder],
            [label("Capture Window"), windowRow],
            [label("OCR"), ocrRow],
            [label("Thumbnail position"), positionPopup],
            [NSGridCell.emptyContentView, shadowsCheckbox],
            [NSGridCell.emptyContentView, pointerCheckbox],
            [NSGridCell.emptyContentView, loginCheckbox],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [closeButton, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            areaRecorder.widthAnchor.constraint(equalToConstant: 160),
            displayRecorder.widthAnchor.constraint(equalToConstant: 160),
            windowRecorder.widthAnchor.constraint(equalToConstant: 160),
            ocrRecorder.widthAnchor.constraint(equalToConstant: 160),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])

        window?.setContentSize(NSSize(width: 440, height: 380))
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private static func title(for position: ThumbnailPosition) -> String {
        switch position {
        case .bottomLeading: return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        case .topLeading: return "Top Left"
        case .topTrailing: return "Top Right"
        }
    }

    private static func position(forTitle title: String) -> ThumbnailPosition {
        switch title {
        case "Bottom Right": return .bottomTrailing
        case "Top Left": return .topLeading
        case "Top Right": return .topTrailing
        default: return .bottomLeading
        }
    }

    // MARK: - Actions

    @objc private func clearWindow() {
        windowRecorder.binding = nil
        windowClear.isEnabled = false
    }

    @objc private func clearOCR() {
        ocrRecorder.binding = nil
        ocrClear.isEnabled = false
    }

    @objc private func checkboxChanged() {
        // Collected on Apply.
    }

    @objc private func loginChanged() {
        onLoginItemChanged?(loginCheckbox.state == .on)
    }

    @objc private func applyClicked() {
        windowClear.isEnabled = windowRecorder.binding != nil
        ocrClear.isEnabled = ocrRecorder.binding != nil
        let draft = collect()
        if onApply?(draft) == true {
            committed = draft
        } else {
            // Conflict or save failure — revert recorded keys (story 7).
            restore(committed)
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }

    private func collect() -> AppPreferences {
        var prefs = AppPreferences()
        if let area = areaRecorder.binding {
            prefs.areaShortcut = area
        }
        if let display = displayRecorder.binding {
            prefs.displayShortcut = display
        }
        prefs.windowShortcut = windowRecorder.binding
        prefs.ocrShortcut = ocrRecorder.binding
        prefs.thumbnailPosition = Self.position(forTitle: positionPopup.titleOfSelectedItem ?? "Bottom Left")
        prefs.includeWindowShadows = shadowsCheckbox.state == .on
        prefs.includePointer = pointerCheckbox.state == .on
        return prefs
    }
}
