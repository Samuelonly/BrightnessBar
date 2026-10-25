import AppKit
import Darwin

/// Menu-bar agent: status item + brightness popover, nothing else.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
