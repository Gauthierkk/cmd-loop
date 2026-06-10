import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "clock.arrow.2.circlepath", accessibilityDescription: "cmdloop") {
                // Size the symbol to the menu bar's text scale so it matches other
                // status items, then render it as a template image. Template images
                // are drawn as vectors at the display's native scale (and tinted for
                // light/dark menu bars), which keeps the glyph crisp on Retina and
                // mixed-DPI multi-monitor setups instead of being rasterized once.
                let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                let configured = img.withSymbolConfiguration(config) ?? img
                configured.isTemplate = true
                button.image = configured
                button.imageScaling = .scaleProportionallyDown
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
