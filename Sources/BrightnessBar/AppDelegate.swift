import AppKit

// NSApplication guarantees delegate callbacks run on the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var panelController: PanelController?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let controller = BrightnessController.make() else {
            FileHandle.standardError.write("BrightnessBar: no controllable display found\n".data(using: .utf8)!)
            exit(1)
        }

        let panel = PanelController(controller: controller)
        panelController = panel
        popover.contentViewController = panel
        popover.behavior = .transient

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "屏幕亮度")
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem?.menu = menu
            button.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            panelController?.prepare()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
