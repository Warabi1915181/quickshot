import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Story 53: pending captures are discarded. No disk write.
    }
}
