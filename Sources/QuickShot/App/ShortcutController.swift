import Foundation
import QuickShotCore

/// Global hotkey registration through `ShortcutServicing` (stories 5–8).
/// Rebind is transactional: on conflict the previous bindings stay active.
@MainActor
final class ShortcutController {
    enum ID: String {
        case area
        case window
        case display
        case ocr
    }

    private let shortcuts: ShortcutServicing
    private var lastGood: AppPreferences

    /// Fired on the main actor with a `ShortcutController.ID` raw value.
    var onTrigger: ((String) -> Void)?

    init(shortcuts: ShortcutServicing, initial: AppPreferences) {
        self.shortcuts = shortcuts
        self.lastGood = initial
    }

    /// Unregister everything, then register from `prefs`.
    /// Area + display are required. Window + OCR register only when non-nil (story 7).
    /// Throws `WorkflowError.shortcutConflict` after restoring `lastGood`.
    func rebind(prefs: AppPreferences) throws {
        shortcuts.unregisterAll()
        do {
            try registerAll(prefs)
            lastGood = prefs
        } catch {
            shortcuts.unregisterAll()
            try? registerAll(lastGood)
            throw error
        }
    }

    func unregisterAll() {
        shortcuts.unregisterAll()
    }

    private func registerAll(_ prefs: AppPreferences) throws {
        try register(id: ID.area.rawValue, binding: prefs.areaShortcut)
        try register(id: ID.display.rawValue, binding: prefs.displayShortcut)
        if let window = prefs.windowShortcut {
            try register(id: ID.window.rawValue, binding: window)
        }
        if let ocr = prefs.ocrShortcut {
            try register(id: ID.ocr.rawValue, binding: ocr)
        }
    }

    private func register(id: String, binding: KeyBinding) throws {
        try shortcuts.register(id: id, binding: binding) { [weak self] in
            // Handler may fire on any queue (ShortcutServicing docs).
            Task { @MainActor in
                self?.onTrigger?(id)
            }
        }
    }
}
