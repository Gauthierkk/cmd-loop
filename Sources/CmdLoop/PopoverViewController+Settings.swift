import AppKit

/// The settings panel: launch-at-login, run-log retention, and clearing logs.
extension PopoverViewController {

    /// Builds the panel's views into `settingsContainer` (hidden by default).
    func buildSettingsPanel() {
        let settingsTitle = NSTextField(labelWithString: "Settings")
        settingsTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Start at login (launch on boot)",
            target: self, action: #selector(toggleLaunchAtLogin(_:))
        )
        launchAtLoginCheckbox.font = .systemFont(ofSize: 13)

        autoAdoptCheckbox = NSButton(
            checkboxWithTitle: "Auto-adopt external entries",
            target: self, action: #selector(toggleAutoAdopt(_:))
        )
        autoAdoptCheckbox.font = .systemFont(ofSize: 13)

        let autoAdoptHint = NSTextField(labelWithString: "Takes ownership of cron/launchd entries added outside cmdloop (about twice a day, and at launch) so their scheduled runs are logged. Undo per-entry with Release.")
        autoAdoptHint.font = .systemFont(ofSize: 10)
        autoAdoptHint.textColor = .secondaryLabelColor
        autoAdoptHint.lineBreakMode = .byWordWrapping
        autoAdoptHint.maximumNumberOfLines = 3
        autoAdoptHint.preferredMaxLayoutWidth = 380

        let clearLogsBtn = NSButton(title: "Clear Logs", target: self, action: #selector(clearLogs))
        clearLogsBtn.bezelStyle = .rounded

        let closeSettingsBtn = NSButton(title: "Done", target: self, action: #selector(hideSettings))
        closeSettingsBtn.bezelStyle = .rounded

        let settingsButtonRow = NSStackView(views: [clearLogsBtn, NSView(), closeSettingsBtn])
        settingsButtonRow.orientation = .horizontal
        settingsButtonRow.spacing = 8

        // Log retention setting: how many runs to keep per job (1–20). Defaults to 1.
        let retentionLabel = NSTextField(labelWithString: "Keep runs per job:")
        retentionLabel.font = .systemFont(ofSize: 13)

        retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        retentionPopup.font = .systemFont(ofSize: 13)
        retentionPopup.addItems(withTitles: (1...20).map(String.init))

        let retentionRow = NSStackView(views: [retentionLabel, retentionPopup])
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 8

        let retentionHint = NSTextField(labelWithString: "Number of most-recent runs to keep per job.")
        retentionHint.font = .systemFont(ofSize: 10)
        retentionHint.textColor = .secondaryLabelColor
        retentionHint.lineBreakMode = .byWordWrapping
        retentionHint.maximumNumberOfLines = 2
        retentionHint.preferredMaxLayoutWidth = 380

        settingsContainer = NSStackView(views: [settingsTitle, launchAtLoginCheckbox, autoAdoptCheckbox, autoAdoptHint, retentionRow, retentionHint, settingsButtonRow])
        settingsContainer.orientation = .vertical
        settingsContainer.alignment = .leading
        settingsContainer.spacing = 10
        settingsContainer.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        settingsContainer.isHidden = true
        settingsContainer.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc func showSettings() {
        addFormContainer.isHidden = true
        hideLogsPanel()
        launchAtLoginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
        autoAdoptCheckbox.state = SettingsStore.shared.autoAdoptExternal ? .on : .off
        // Select the stored run count, clamped into the 1...20 menu.
        let stored = min(max(SettingsStore.shared.logRetentionRuns, 1), 20)
        retentionPopup.selectItem(withTitle: String(stored))
        settingsContainer.isHidden = false
        resizePopover()
    }

    @objc private func hideSettings() {
        // Persist retention on Done (a run count of 1...20) and prune immediately so
        // the change is visible.
        if let title = retentionPopup.titleOfSelectedItem, let n = Int(title) {
            SettingsStore.shared.logRetentionRuns = n
        }
        RunLogStore.shared.prune()
        settingsContainer.isHidden = true
        resizePopover()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        LoginItemManager.shared.setEnabled(sender.state == .on)
        // Reflect the actual on-disk state in case the change didn't take.
        launchAtLoginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
    }

    @objc private func toggleAutoAdopt(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsStore.shared.autoAdoptExternal = enabled
        (NSApp.delegate as? AppDelegate)?.updateAutoAdoptTimer()
        // Adopt what's already there right away, so turning it on takes effect
        // immediately rather than waiting for the next scheduled scrape.
        if enabled { SchedulerManager.shared.autoAdoptScrape() }
    }

    @objc private func clearLogs() {
        RunLogStore.shared.clearAll()
        if logsJob != nil, !logsContainer.isHidden {
            logsRuns = []
            refreshLogsPanel()
        }
    }
}
