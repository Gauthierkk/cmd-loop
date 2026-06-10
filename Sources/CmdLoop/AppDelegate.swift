import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "clock.arrow.2.circlepath", accessibilityDescription: "cmdloop") {
                // Marking the symbol as a template lets AppKit draw it as a vector
                // sized to fit the menu bar — crisp on Retina and mixed-DPI setups,
                // and auto-tinted for light/dark bars. We deliberately do NOT force a
                // large pointSize: this glyph's repeat-arrows extend above and below
                // the clock face, so an oversized config makes the top/bottom clip.
                // Letting the system size it keeps the whole glyph inside the bar.
                img.isTemplate = true
                button.image = img
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let vc = PopoverViewController()
        popover = NSPopover()
        popover.contentSize = NSSize(width: PopoverLayout.width, height: 100)
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.popover = popover

        let jobs = ConfigManager.shared.load()
        CrontabManager.shared.sync(jobs)
        RunLogStore.shared.prune()
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
