import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    // Menu-bar utility: no Dock icon, never becomes the active app.
    app.setActivationPolicy(.accessory)
    app.run()
}
