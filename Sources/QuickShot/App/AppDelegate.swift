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
        // Pending captures are discarded; temporary drag exports are not history.
        ThumbnailDragFileStore.shared.cleanup()
    }
}
