import Foundation
import QuickShotCore

/// UserDefaults-backed store for `AppPreferences`. Keys live under `quickshot.*`.
@MainActor
final class PreferencesStore {
    private let defaults: UserDefaults

    private enum Keys {
        static let areaKey = "quickshot.areaKey"
        static let displayKey = "quickshot.displayKey"
        static let windowKey = "quickshot.windowKey"
        static let ocrKey = "quickshot.ocrKey"
        static let thumbnailPosition = "quickshot.thumbnailPosition"
        static let includePointer = "quickshot.includePointer"
        static let includeWindowShadows = "quickshot.includeWindowShadows"
    }

    private struct StoredBinding: Codable {
        var keyCode: UInt32
        var modifiers: UInt32

        init(_ binding: KeyBinding) {
            keyCode = binding.keyCode
            modifiers = binding.modifiers
        }

        var binding: KeyBinding {
            KeyBinding(keyCode: keyCode, modifiers: modifiers)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppPreferences {
        // Missing keys fall back to AppPreferences() defaults (stories 5–6, 15–18, 20).
        var prefs = AppPreferences()
        if let area = loadBinding(Keys.areaKey) {
            prefs.areaShortcut = area
        }
        if let display = loadBinding(Keys.displayKey) {
            prefs.displayShortcut = display
        }
        prefs.windowShortcut = loadBinding(Keys.windowKey)
        prefs.ocrShortcut = loadBinding(Keys.ocrKey)
        if let raw = defaults.string(forKey: Keys.thumbnailPosition),
           let position = ThumbnailPosition(rawValue: raw) {
            prefs.thumbnailPosition = position
        }
        if defaults.object(forKey: Keys.includePointer) != nil {
            prefs.includePointer = defaults.bool(forKey: Keys.includePointer)
        }
        if defaults.object(forKey: Keys.includeWindowShadows) != nil {
            prefs.includeWindowShadows = defaults.bool(forKey: Keys.includeWindowShadows)
        }
        return prefs
    }

    func save(_ prefs: AppPreferences) {
        saveBinding(prefs.areaShortcut, Keys.areaKey)
        saveBinding(prefs.displayShortcut, Keys.displayKey)
        saveBinding(prefs.windowShortcut, Keys.windowKey)
        saveBinding(prefs.ocrShortcut, Keys.ocrKey)
        defaults.set(prefs.thumbnailPosition.rawValue, forKey: Keys.thumbnailPosition)
        defaults.set(prefs.includePointer, forKey: Keys.includePointer)
        defaults.set(prefs.includeWindowShadows, forKey: Keys.includeWindowShadows)
    }

    private func loadBinding(_ key: String) -> KeyBinding? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredBinding.self, from: data).binding
    }

    private func saveBinding(_ binding: KeyBinding?, _ key: String) {
        guard let binding else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(StoredBinding(binding)) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
