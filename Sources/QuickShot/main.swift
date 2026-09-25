import AppKit

// Top-level main.swift is nonisolated; hop to MainActor before touching AppKit.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only at launch (story 3). Dock appears later via setActivationPolicy (story 4).
    app.setActivationPolicy(.accessory)
    app.run()
}
