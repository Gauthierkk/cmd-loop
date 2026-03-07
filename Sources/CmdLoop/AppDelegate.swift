import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "clock.arrow.2.circlepath", accessibilityDescription: "cmdloop") {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                button.image = img.withSymbolConfiguration(config)
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let vc = PopoverViewController()
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 100)
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.popover = popover

        let jobs = ConfigManager.shared.load()
        CrontabManager.shared.sync(jobs)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
