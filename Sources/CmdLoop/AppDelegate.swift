import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    /// Fires the periodic auto-adopt scrape (~twice a day) while the app runs.
    private var autoAdoptTimer: Timer?

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
        // Build the popover's view now so the first click doesn't pay for UI
        // construction plus the crontab read.
        _ = vc.view

        // Reconciling the schedulers shells out to crontab/launchctl; keep it
        // off the main thread so launch stays instant. An auto-adopt scrape (if
        // enabled) runs after the sync, in the same block, to avoid racing it.
        DispatchQueue.global(qos: .utility).async {
            let jobs = ConfigManager.shared.load()
            RunLogStore.shared.migrateLegacyLogs(for: jobs)
            SchedulerManager.shared.syncManaged(jobs)
            RunLogStore.shared.prune()
            if SettingsStore.shared.autoAdoptExternal,
               SchedulerManager.shared.adoptAllExternal() > 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .jobsDidChange, object: nil)
                }
            }
        }

        updateAutoAdoptTimer()
    }

    /// Starts or stops the periodic auto-adopt scrape to match the setting, so the
    /// app only wakes for it while auto-adopt is on. Re-scrapes roughly twice a day
    /// so entries added later get adopted without needing an app restart; coarse
    /// tolerance lets the OS coalesce the wakeup.
    func updateAutoAdoptTimer() {
        autoAdoptTimer?.invalidate()
        autoAdoptTimer = nil
        guard SettingsStore.shared.autoAdoptExternal else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in
            SchedulerManager.shared.autoAdoptScrape()
        }
        timer.tolerance = 3600
        autoAdoptTimer = timer
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
