import AppKit

// `.accessory` keeps QuickTalk out of the Dock and the ⌘-Tab switcher: it lives in the
// menu bar and the floating pill, nowhere else.
let app = NSApplication.shared

// Top-level code is nonisolated, but it does run on the main thread — and AppDelegate is
// @MainActor because every part of it touches AppKit.
let delegate = MainActor.assumeIsolated { AppDelegate() }

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
