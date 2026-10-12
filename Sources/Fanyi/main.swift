import AppKit

// Manual NSApplication bootstrap (no SwiftUI @main App).
// Top-level code runs on the main thread; assumeIsolated makes that explicit
// to the concurrency checker.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    AppDelegate.retained = delegate   // NSApplication.delegate is weak
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
