import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService` (story 2).
@MainActor
final class LoginItemController {
    init() {}

    /// Best-effort register on launch. User may deny; ignore failure.
    func registerAtLaunch() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Denied or unavailable — Settings checkbox can retry.
        }
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
