import AppKit
import QuickShotCore

/// Menu bar status item + capture menu (stories 1, 8).
/// Menu actions call AppController closures — never adapters directly.
@MainActor
final class StatusItemController: NSObject {
    var onArea: (() -> Void)?
    var onWindow: (() -> Void)?
    var onDisplay: (() -> Void)?
    var onOCRImage: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?
    private weak var areaItem: NSMenuItem?
    private weak var windowItem: NSMenuItem?
    private weak var displayItem: NSMenuItem?
    private weak var ocrItem: NSMenuItem?

    private static let baseArea = "Capture Area"
    private static let baseWindow = "Capture Window"
    private static let baseDisplay = "Capture Display"
    private static let baseOCR = "OCR Image…"

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.on.rectangle", accessibilityDescription: "QuickShot")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "QuickShot"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let area = makeItem(Self.baseArea, action: #selector(doArea))
        let window = makeItem(Self.baseWindow, action: #selector(doWindow))
        let display = makeItem(Self.baseDisplay, action: #selector(doDisplay))
        let ocr = makeItem(Self.baseOCR, action: #selector(doOCRImage))

        let settings = makeItem("Settings…", action: #selector(doSettings))
        let quit = makeItem("Quit QuickShot", action: #selector(doQuit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]

        menu.addItem(area)
        menu.addItem(window)
        menu.addItem(display)
        menu.addItem(ocr)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)

        areaItem = area
        windowItem = window
        displayItem = display
        ocrItem = ocr

        item.menu = menu
        statusItem = item
    }

    /// Nice-to-have glyph suffix on menu titles (not keyEquivalent — avoids double fire).
    func updateShortcutHints(_ prefs: AppPreferences) {
        areaItem?.title = Self.baseArea + hint(prefs.areaShortcut)
        displayItem?.title = Self.baseDisplay + hint(prefs.displayShortcut)
        windowItem?.title = Self.baseWindow + hint(prefs.windowShortcut)
        ocrItem?.title = Self.baseOCR + hint(prefs.ocrShortcut)
    }

    private func hint(_ binding: KeyBinding?) -> String {
        guard let binding else { return "" }
        return "    " + ShortcutGlyph.string(for: binding)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func doArea() { onArea?() }
    @objc private func doWindow() { onWindow?() }
    @objc private func doDisplay() { onDisplay?() }
    @objc private func doOCRImage() { onOCRImage?() }
    @objc private func doSettings() { onSettings?() }
    @objc private func doQuit() { onQuit?() }
}
