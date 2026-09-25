import AppKit

/// Screen Recording guidance + recoverable error alerts (stories 54–55).
@MainActor
final class PermissionAlertController {
    init() {}

    /// First-use / denied sheet. Retry runs the grant attempt; Cancel reports denial.
    func show(onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording Access"
        alert.informativeText = """
        QuickShot needs Screen Recording permission to capture the display.

        Open System Settings → Privacy & Security → Screen & System Audio Recording, \
        enable QuickShot, then retry capture. If QuickShot already appears enabled, \
        switch it off and back on for this build, then relaunch QuickShot.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Self.openScreenCaptureSettings()
        case .alertSecondButtonReturn:
            onContinue()
        default:
            onCancel()
        }
    }

    /// Story 55. Appends thumbnail-still-available suffix when the pending item remains.
    func showError(_ message: String, captureStillAvailable: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "QuickShot"
        var text = message
        if captureStillAvailable {
            text += "\n\nThe capture is still available in its thumbnail."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showPermissionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "QuickShot"
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openScreenCaptureSettings()
        }
    }

    static func openScreenCaptureSettings() {
        // SMAppService.openSystemSettingsLoginItems is the wrong pane (story 54).
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
