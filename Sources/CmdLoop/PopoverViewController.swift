import AppKit

class PopoverViewController: NSViewController, JobRowDelegate {
    private var stackView: NSStackView!
    private var addFormContainer: NSStackView!
    private var nameField: NSTextField!
    private var commandTextView: NSTextView!
    private var cronField: NSTextField!
    private var backendSelector: NSSegmentedControl!
    private var launchdContainer: NSStackView!
    private var launchdModeSelector: NSSegmentedControl!
    private var minuteField, hourField, dayField, weekdayField, monthField: NSTextField!
    private var calendarGroup: NSStackView!
    private var intervalField: NSTextField!
    private var intervalUnitSelector: NSSegmentedControl!
    private var intervalRow: NSStackView!
    private var scheduleReadOnlyLabel: NSTextField!
    private var editingScheduleReadOnly = false
    private var settingsContainer: NSStackView!
    private var launchAtLoginCheckbox: NSButton!
    private var retentionField: NSTextField!
    private var logsContainer: NSStackView!
    private var logsTitleLabel: NSTextField!
    private var logsSummaryLabel: NSTextField!
    private var logsTerminal: TerminalView!
    private var expandRunsBtn: NSButton!
    private var runListStack: NSStackView!
    private var paginationRow: NSStackView!
    private var pageLabel: NSTextField!
    private var prevPageBtn: NSButton!
    private var nextPageBtn: NSButton!
    private var logsJob: CronJob?
    private var logsRuns: [RunRecord] = []
    private var logsPage = 0
    private var logsExpanded = false
    private var selectedRunIndex = 0
    private var jobs: [CronJob] = []
    private var editingJob: CronJob?
    private var externalEditHint: NSTextField!
    weak var popover: NSPopover?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: PopoverLayout.width, height: 100))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadJobs()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshJobs),
            name: .jobsDidChange, object: nil
        )
    }

    private func setupUI() {
        // Job list stack
        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 8, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Add form (hidden by default)
        nameField = NSTextField()
        nameField.placeholderString = "Name"
        nameField.font = .systemFont(ofSize: 14)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        cronField = NSTextField()
        cronField.placeholderString = "Cron (e.g., */5 * * * *)"
        cronField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        cronField.translatesAutoresizingMaskIntoConstraints = false
        cronField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // Multi-line command input
        commandTextView = NSTextView()
        commandTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        commandTextView.isRichText = false
        commandTextView.isAutomaticQuoteSubstitutionEnabled = false
        commandTextView.isAutomaticTextReplacementEnabled = false
        commandTextView.textContainerInset = NSSize(width: 4, height: 4)

        let cmdScroll = NSScrollView()
        cmdScroll.documentView = commandTextView
        cmdScroll.hasVerticalScroller = true
        cmdScroll.borderType = .bezelBorder
        cmdScroll.translatesAutoresizingMaskIntoConstraints = false
        cmdScroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        commandTextView.minSize = NSSize(width: 0, height: 48)
        commandTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        commandTextView.isVerticallyResizable = true
        commandTextView.isHorizontallyResizable = false
        commandTextView.autoresizingMask = [.width]
        commandTextView.textContainer?.widthTracksTextView = true

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveNewJob))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(hideAddForm))
        cancelBtn.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [NSView(), cancelBtn, saveBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // Hint shown when renaming an external (non-cmdloop) cron entry.
        externalEditHint = NSTextField(labelWithString: "External cron entry — changes are written directly to your crontab.")
        externalEditHint.font = .systemFont(ofSize: 11)
        externalEditHint.textColor = .secondaryLabelColor
        externalEditHint.lineBreakMode = .byWordWrapping
        externalEditHint.maximumNumberOfLines = 2
        externalEditHint.isHidden = true

        // Backend picker: which local scheduler runs the job.
        backendSelector = NSSegmentedControl(
            labels: ["Cron", "Launchd"], trackingMode: .selectOne,
            target: self, action: #selector(backendChanged)
        )
        backendSelector.selectedSegment = 0
        backendSelector.translatesAutoresizingMaskIntoConstraints = false

        // Launchd schedule editor: a Calendar / Interval mode selector over native
        // launchd fields (StartCalendarInterval / StartInterval).
        launchdModeSelector = NSSegmentedControl(
            labels: ["Calendar", "Interval"], trackingMode: .selectOne,
            target: self, action: #selector(launchdModeChanged)
        )
        launchdModeSelector.selectedSegment = 0

        func calField(_ placeholder: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.alignment = .center
            f.translatesAutoresizingMaskIntoConstraints = false
            f.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return f
        }
        minuteField = calField("min")
        hourField = calField("hour")
        dayField = calField("day")
        weekdayField = calField("wday")
        monthField = calField("month")
        let calendarRow = NSStackView(views: [minuteField, hourField, dayField, weekdayField, monthField])
        calendarRow.orientation = .horizontal
        calendarRow.distribution = .fillEqually
        calendarRow.spacing = 4

        let calHint = NSTextField(labelWithString: "Blank = every. Fields: minute, hour, day, weekday (Sun=0), month.")
        calHint.font = .systemFont(ofSize: 10)
        calHint.textColor = .secondaryLabelColor
        calHint.lineBreakMode = .byWordWrapping
        calHint.maximumNumberOfLines = 2

        calendarGroup = NSStackView(views: [calendarRow, calHint])
        calendarGroup.orientation = .vertical
        calendarGroup.alignment = .width
        calendarGroup.spacing = 4

        let everyLabel = NSTextField(labelWithString: "Every")
        everyLabel.font = .systemFont(ofSize: 12)
        intervalField = NSTextField()
        intervalField.placeholderString = "N"
        intervalField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        intervalField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        intervalUnitSelector = NSSegmentedControl(
            labels: ["minutes", "seconds"], trackingMode: .selectOne, target: nil, action: nil
        )
        intervalUnitSelector.selectedSegment = 0
        intervalRow = NSStackView(views: [everyLabel, intervalField, intervalUnitSelector, NSView()])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 6

        scheduleReadOnlyLabel = NSTextField(labelWithString: "")
        scheduleReadOnlyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scheduleReadOnlyLabel.textColor = .secondaryLabelColor
        scheduleReadOnlyLabel.lineBreakMode = .byWordWrapping
        scheduleReadOnlyLabel.maximumNumberOfLines = 3
        scheduleReadOnlyLabel.isHidden = true

        launchdContainer = NSStackView(views: [launchdModeSelector, calendarGroup, intervalRow, scheduleReadOnlyLabel])
        launchdContainer.orientation = .vertical
        launchdContainer.alignment = .width
        launchdContainer.spacing = 8
        launchdContainer.isHidden = true

        addFormContainer = NSStackView(views: [nameField, externalEditHint, backendSelector, cronField, launchdContainer, cmdScroll, buttonRow])
        addFormContainer.orientation = .vertical
        addFormContainer.alignment = .width
        addFormContainer.spacing = 10
        addFormContainer.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        addFormContainer.isHidden = true
        addFormContainer.translatesAutoresizingMaskIntoConstraints = false

        // Settings panel (hidden by default)
        let settingsTitle = NSTextField(labelWithString: "Settings")
        settingsTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Start at login (launch on boot)",
            target: self, action: #selector(toggleLaunchAtLogin(_:))
        )
        launchAtLoginCheckbox.font = .systemFont(ofSize: 13)

        let clearLogsBtn = NSButton(title: "Clear Logs", target: self, action: #selector(clearLogs))
        clearLogsBtn.bezelStyle = .rounded

        let closeSettingsBtn = NSButton(title: "Done", target: self, action: #selector(hideSettings))
        closeSettingsBtn.bezelStyle = .rounded

        let settingsButtonRow = NSStackView(views: [clearLogsBtn, NSView(), closeSettingsBtn])
        settingsButtonRow.orientation = .horizontal
        settingsButtonRow.spacing = 8

        // Log retention setting: a run count per job; empty falls back to the
        // default time-based policy (delete runs older than 10 days).
        let retentionLabel = NSTextField(labelWithString: "Keep runs per job:")
        retentionLabel.font = .systemFont(ofSize: 13)

        retentionField = NSTextField()
        retentionField.placeholderString = "10-day default"
        retentionField.font = .systemFont(ofSize: 13)
        retentionField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let retentionRow = NSStackView(views: [retentionLabel, retentionField])
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 8

        let retentionHint = NSTextField(labelWithString: "Number of runs to keep per job. Leave empty to keep runs from the last 10 days.")
        retentionHint.font = .systemFont(ofSize: 10)
        retentionHint.textColor = .secondaryLabelColor
        retentionHint.lineBreakMode = .byWordWrapping
        retentionHint.maximumNumberOfLines = 2
        retentionHint.preferredMaxLayoutWidth = 380

        settingsContainer = NSStackView(views: [settingsTitle, launchAtLoginCheckbox, retentionRow, retentionHint, settingsButtonRow])
        settingsContainer.orientation = .vertical
        settingsContainer.alignment = .leading
        settingsContainer.spacing = 10
        settingsContainer.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        settingsContainer.isHidden = true
        settingsContainer.translatesAutoresizingMaskIntoConstraints = false

        // Logs panel (hidden by default)
        logsTitleLabel = NSTextField(labelWithString: "")
        logsTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        logsTitleLabel.lineBreakMode = .byTruncatingTail

        let closeLogsBtn = NSButton(title: "✕ Close", target: self, action: #selector(hideLogs))
        closeLogsBtn.bezelStyle = .toolbar
        closeLogsBtn.font = .systemFont(ofSize: 11)

        let logsHeader = NSStackView(views: [logsTitleLabel, NSView(), closeLogsBtn])
        logsHeader.orientation = .horizontal
        logsHeader.spacing = 4
        logsHeader.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 0, right: 8)

        logsSummaryLabel = NSTextField(labelWithString: "")
        logsSummaryLabel.font = .systemFont(ofSize: 11)
        logsSummaryLabel.textColor = .secondaryLabelColor
        logsSummaryLabel.lineBreakMode = .byTruncatingTail

        let summaryRow = NSStackView(views: [logsSummaryLabel])
        summaryRow.orientation = .horizontal
        summaryRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        logsTerminal = TerminalView()

        expandRunsBtn = NSButton(title: "Show previous runs ▾", target: self, action: #selector(toggleRunList))
        expandRunsBtn.bezelStyle = .toolbar
        expandRunsBtn.font = .systemFont(ofSize: 11)

        let expandRow = NSStackView(views: [expandRunsBtn, NSView()])
        expandRow.orientation = .horizontal
        expandRow.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 10, right: 12)

        runListStack = NSStackView()
        runListStack.orientation = .vertical
        runListStack.alignment = .leading
        runListStack.spacing = 2
        runListStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 12)
        runListStack.isHidden = true

        prevPageBtn = NSButton(title: "‹ Prev", target: self, action: #selector(prevPage))
        prevPageBtn.bezelStyle = .toolbar
        prevPageBtn.font = .systemFont(ofSize: 11)

        nextPageBtn = NSButton(title: "Next ›", target: self, action: #selector(nextPage))
        nextPageBtn.bezelStyle = .toolbar
        nextPageBtn.font = .systemFont(ofSize: 11)

        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor

        paginationRow = NSStackView(views: [prevPageBtn, pageLabel, nextPageBtn, NSView()])
        paginationRow.orientation = .horizontal
        paginationRow.spacing = 8
        paginationRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 10, right: 12)
        paginationRow.isHidden = true

        logsContainer = NSStackView(views: [logsHeader, summaryRow, centeredTerminalRow(logsTerminal), expandRow, runListStack, paginationRow])
        logsContainer.orientation = .vertical
        logsContainer.alignment = .width
        logsContainer.spacing = 8
        logsContainer.isHidden = true
        logsContainer.translatesAutoresizingMaskIntoConstraints = false

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Footer: icon-only buttons — settings, add, quit.
        func footerButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
            let btn = NSButton(title: "", target: self, action: action)
            btn.bezelStyle = .toolbar
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            btn.imagePosition = .imageOnly
            btn.toolTip = tooltip
            btn.translatesAutoresizingMaskIntoConstraints = false
            return btn
        }

        let settingsBtn = footerButton(symbol: "gearshape", tooltip: "Settings", action: #selector(showSettings))
        let addBtn = footerButton(symbol: "plus", tooltip: "Add command", action: #selector(showAddForm))
        let quitBtn = footerButton(symbol: "power", tooltip: "Quit cmdloop", action: #selector(quitApp))

        // Flexible equal-width spacers on both ends center the footer buttons.
        let leftSpacer = NSView()
        let rightSpacer = NSView()
        let bottomRow = NSStackView(views: [leftSpacer, settingsBtn, addBtn, quitBtn, rightSpacer])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 16
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        leftSpacer.widthAnchor.constraint(equalTo: rightSpacer.widthAnchor).isActive = true

        // Main layout
        let mainStack = NSStackView(views: [stackView, logsContainer, addFormContainer, settingsContainer, separator, bottomRow])
        mainStack.orientation = .vertical
        mainStack.spacing = 0
        // Stretch every section to the stack's full width. The default (.centerX)
        // gives each panel only its fitting width, which made the two terminal
        // views render at different sizes depending on their sibling content.
        mainStack.alignment = .width
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Explicitly pin every section — and every row inside the multi-row
        // panels — to its container's full width. Relying on stack alignment
        // alone proved flaky inside NSPopover, intermittently leaving panels at
        // their fitting width and hugging the trailing edge.
        for section in mainStack.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }
        // (Only the inset-free logs panel: the add form and settings panels have
        // edge insets, where a full-width pin would conflict.)
        for row in logsContainer.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: logsContainer.widthAnchor).isActive = true
        }
    }

    /// Wraps a terminal in a full-width row that centers it at the shared
    /// proportional width (80% of the popover).
    private func centeredTerminalRow(_ terminal: TerminalView) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: wrapper.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            terminal.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            terminal.widthAnchor.constraint(equalTo: wrapper.widthAnchor, multiplier: PopoverLayout.terminalWidthRatio),
        ])
        return wrapper
    }

    private func loadJobs() {
        jobs = SchedulerManager.shared.loadAllJobs()
        rebuildJobList()
    }

    /// Jobs cmdloop owns. External crontab entries are excluded so they're never
    /// persisted to config.json or rewritten with cmdloop markers.
    private var managedJobs: [CronJob] {
        jobs.filter { $0.source == .managed }
    }

    private func persistManagedJobs() {
        let managed = managedJobs
        ConfigManager.shared.save(managed)
        SchedulerManager.shared.syncManaged(managed)
    }

    @objc private func refreshJobs() {
        loadJobs()
        if let job = logsJob, !logsContainer.isHidden {
            logsRuns = RunLogStore.shared.runs(for: job)
            refreshLogsPanel()
        }
    }

    private func rebuildJobList() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if jobs.isEmpty {
            let label = NSTextField(labelWithString: "No commands configured")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
                wrapper.heightAnchor.constraint(equalToConstant: 40),
            ])
            stackView.addArrangedSubview(wrapper)
        } else {
            for job in jobs {
                let row = JobRowView(job: job, delegate: self)
                stackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }
        resizePopover()
    }

    private func resizePopover() {
        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        let newHeight = min(fittingSize.height, PopoverLayout.maxHeight)
        popover?.contentSize = NSSize(width: PopoverLayout.width, height: newHeight)
    }

    @objc private func showAddForm() {
        editingJob = nil
        settingsContainer.isHidden = true
        logsContainer.isHidden = true
        addFormContainer.isHidden = false
        nameField.stringValue = ""
        commandTextView.string = ""
        editingScheduleReadOnly = false
        backendSelector.selectedSegment = 0
        backendSelector.isEnabled = true
        resetScheduleFields()
        updateScheduleFieldVisibility()
        setCommandFieldsEditable(true)
        externalEditHint.isHidden = true
        resizePopover()
        view.window?.makeFirstResponder(nameField)
    }

    private func showEditForm(for job: CronJob) {
        editingJob = job
        settingsContainer.isHidden = true
        logsContainer.isHidden = true
        addFormContainer.isHidden = false
        nameField.stringValue = (job.name == "cronjob" || job.name == "launchd job") ? "" : job.name
        commandTextView.string = job.command
        resetScheduleFields()

        editingScheduleReadOnly = false
        switch job.backend {
        case .cron:
            backendSelector.selectedSegment = 0
            cronField.stringValue = job.cronExpression
        case .launchd:
            backendSelector.selectedSegment = 1
            populateLaunchdFields(from: job.schedule)
            // An external agent whose schedule can't round-trip the editor (multiple
            // calendar dicts) is shown read-only; command and name still apply.
            if job.source == .external, !LaunchDManager.shared.isEditableSchedule(job.schedule) {
                editingScheduleReadOnly = true
                scheduleReadOnlyLabel.stringValue =
                    "Schedule: \(job.schedule.displaySummary)\nThis agent's schedule can't be edited here; editing keeps it as-is."
            }
        }
        // Backend can only be switched for cmdloop-managed jobs; external entries
        // stay on the backend they came from.
        backendSelector.isEnabled = (job.source == .managed)
        updateScheduleFieldVisibility()

        // External entries are fully editable; saving rewrites their scheduler entry
        // directly. Show a note so it's clear the change isn't sandboxed.
        let isExternal = job.source == .external
        externalEditHint.stringValue = job.backend == .launchd
            ? "External launchd agent — changes are written directly to its plist in ~/Library/LaunchAgents."
            : "External cron entry — changes are written directly to your crontab."
        setCommandFieldsEditable(true)
        externalEditHint.isHidden = !isExternal

        resizePopover()
        view.window?.makeFirstResponder(nameField)
    }

    /// Enables/disables the command + cron inputs and dims them when read-only.
    private func setCommandFieldsEditable(_ editable: Bool) {
        cronField.isEditable = editable
        cronField.isSelectable = true
        cronField.textColor = editable ? .labelColor : .secondaryLabelColor
        commandTextView.isEditable = editable
        commandTextView.textColor = editable ? .textColor : .secondaryLabelColor
    }

    @objc private func hideAddForm() {
        addFormContainer.isHidden = true
        editingJob = nil
        resizePopover()
    }

    // MARK: - Schedule editor

    @objc private func backendChanged() {
        updateScheduleFieldVisibility()
        resizePopover()
    }

    @objc private func launchdModeChanged() {
        updateLaunchdModeVisibility()
        resizePopover()
    }

    private var isLaunchdSelected: Bool { backendSelector.selectedSegment == 1 }

    /// Shows the cron field or the launchd editor depending on the backend picker.
    private func updateScheduleFieldVisibility() {
        cronField.isHidden = isLaunchdSelected
        launchdContainer.isHidden = !isLaunchdSelected
        if isLaunchdSelected { updateLaunchdModeVisibility() }
    }

    private func updateLaunchdModeVisibility() {
        if editingScheduleReadOnly {
            launchdModeSelector.isHidden = true
            calendarGroup.isHidden = true
            intervalRow.isHidden = true
            scheduleReadOnlyLabel.isHidden = false
            return
        }
        scheduleReadOnlyLabel.isHidden = true
        launchdModeSelector.isHidden = false
        let calendar = launchdModeSelector.selectedSegment == 0
        calendarGroup.isHidden = !calendar
        intervalRow.isHidden = calendar
    }

    private func resetScheduleFields() {
        cronField.stringValue = ""
        [minuteField, hourField, dayField, weekdayField, monthField, intervalField]
            .forEach { $0?.stringValue = "" }
        intervalUnitSelector.selectedSegment = 0
        launchdModeSelector.selectedSegment = 0
        resetScheduleFieldBackgrounds()
    }

    private func resetScheduleFieldBackgrounds() {
        cronField.backgroundColor = .controlBackgroundColor
        [minuteField, hourField, dayField, weekdayField, monthField, intervalField]
            .forEach { $0?.backgroundColor = .controlBackgroundColor }
    }

    private func populateLaunchdFields(from schedule: JobSchedule) {
        switch schedule {
        case .interval(let seconds):
            launchdModeSelector.selectedSegment = 1
            if seconds % 60 == 0 {
                intervalField.stringValue = String(seconds / 60)
                intervalUnitSelector.selectedSegment = 0
            } else {
                intervalField.stringValue = String(seconds)
                intervalUnitSelector.selectedSegment = 1
            }
        case .calendar(let intervals):
            launchdModeSelector.selectedSegment = 0
            if let i = intervals.first {
                minuteField.stringValue = i.minute.map(String.init) ?? ""
                hourField.stringValue = i.hour.map(String.init) ?? ""
                dayField.stringValue = i.day.map(String.init) ?? ""
                weekdayField.stringValue = i.weekday.map(String.init) ?? ""
                monthField.stringValue = i.month.map(String.init) ?? ""
            }
        case .cron:
            launchdModeSelector.selectedSegment = 0
        }
    }

    /// Reads a launchd schedule from the editor. Returns nil if any field is
    /// invalid (non-integer or out of range, or a non-positive interval).
    private func readLaunchdSchedule() -> JobSchedule? {
        if launchdModeSelector.selectedSegment == 1 {
            guard let n = Int(intervalField.stringValue.trimmingCharacters(in: .whitespaces)), n > 0 else {
                return nil
            }
            return .interval(intervalUnitSelector.selectedSegment == 0 ? n * 60 : n)
        }
        let m = parseCalField(minuteField, valid: 0...59)
        let h = parseCalField(hourField, valid: 0...23)
        let d = parseCalField(dayField, valid: 1...31)
        let wd = parseCalField(weekdayField, valid: 0...7)
        let mo = parseCalField(monthField, valid: 1...12)
        guard m.ok, h.ok, d.ok, wd.ok, mo.ok else { return nil }
        return .calendar([CalendarInterval(
            minute: m.value, hour: h.value, day: d.value, weekday: wd.value, month: mo.value
        )])
    }

    /// Parses one calendar field: blank or "*" means "every" (nil); otherwise an
    /// integer in range. `ok == false` signals an invalid entry.
    private func parseCalField(_ field: NSTextField, valid: ClosedRange<Int>) -> (ok: Bool, value: Int?) {
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "*" { return (true, nil) }
        guard let v = Int(s), valid.contains(v) else { return (false, nil) }
        return (true, v)
    }

    private func flashInvalidSchedule() {
        let red = NSColor.systemRed.withAlphaComponent(0.15)
        if launchdModeSelector.selectedSegment == 1 {
            intervalField.backgroundColor = red
        } else {
            [minuteField, hourField, dayField, weekdayField, monthField].forEach {
                $0?.backgroundColor = red
            }
        }
    }

    @objc private func saveNewJob() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let command = commandTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return }

        // Build and validate the schedule from whichever editor is active.
        guard let schedule = buildScheduleFromForm() else { return }
        let backend: JobBackend = isLaunchdSelected ? .launchd : .cron

        // Editing an external entry: rewrite the underlying scheduler entry directly.
        if let editing = editingJob, editing.source == .external {
            switch editing.backend {
            case .cron:
                saveExternalCronEdit(editing: editing, name: name, command: command, schedule: schedule)
            case .launchd:
                SchedulerManager.shared.updateExternalLaunchd(editing, command: command, schedule: schedule)
                if let ref = LaunchDManager.shared.externalAgents[editing.id] {
                    ExternalNameStore.shared.setName(name, for: LaunchDManager.shared.externalNameKey(label: ref.label))
                }
            }
            editingJob = nil
            addFormContainer.isHidden = true
            loadJobs()
            return
        }

        // Managed create / edit.
        if let editId = editingJob?.id, let idx = jobs.firstIndex(where: { $0.id == editId }) {
            // Switching away from launchd leaves an orphan plist; remove it first.
            if jobs[idx].backend == .launchd, backend != .launchd {
                SchedulerManager.shared.deleteManaged(jobs[idx])
            }
            jobs[idx].name = name
            jobs[idx].command = command
            jobs[idx].schedule = schedule
            jobs[idx].backend = backend
        } else {
            jobs.append(CronJob(name: name, command: command, schedule: schedule, backend: backend))
        }
        editingJob = nil
        persistManagedJobs()
        rebuildJobList()
        addFormContainer.isHidden = true
        resizePopover()
    }

    /// Reads and validates the schedule from the active editor, flashing the
    /// offending field and returning nil on invalid input.
    private func buildScheduleFromForm() -> JobSchedule? {
        // Preserve an un-editable external launchd schedule (multi-dict calendar).
        if editingScheduleReadOnly, let editing = editingJob {
            return editing.schedule
        }
        if isLaunchdSelected {
            guard let schedule = readLaunchdSchedule() else {
                flashInvalidSchedule()
                return nil
            }
            return schedule
        }
        let cron = cronField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !cron.isEmpty, (try? CronParser(cron)) != nil else {
            cronField.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15)
            return nil
        }
        return .cron(cron)
    }

    /// Rewrites an external cron entry's line if schedule/command changed, carrying
    /// its stored name and run history to the new content-derived identity.
    private func saveExternalCronEdit(editing: CronJob, name: String, command: String, schedule: JobSchedule) {
        guard case .cron(let cron) = schedule else { return }
        if cron != editing.cronExpression || command != editing.command {
            CrontabManager.shared.updateExternalEntry(
                oldCron: editing.cronExpression, oldCommand: editing.command,
                newCron: cron, newCommand: command
            )
            let oldKey = ExternalNameStore.key(cron: editing.cronExpression, command: editing.command)
            ExternalNameStore.shared.setName("", for: oldKey)
            let newKey = ExternalNameStore.key(cron: cron, command: command)
            RunLogStore.shared.moveHistory(
                from: deterministicUUID(from: oldKey),
                to: deterministicUUID(from: newKey)
            )
        }
        let newKey = ExternalNameStore.key(cron: cron, command: command)
        ExternalNameStore.shared.setName(name, for: newKey)
    }

    // MARK: - Settings

    @objc private func showSettings() {
        addFormContainer.isHidden = true
        logsContainer.isHidden = true
        launchAtLoginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
        retentionField.stringValue = SettingsStore.shared.logRetentionRuns.map(String.init) ?? ""
        settingsContainer.isHidden = false
        resizePopover()
    }

    @objc private func hideSettings() {
        // Persist retention on Done: a positive run count, or empty for the
        // default 10-day policy. Prune immediately so the change is visible.
        let entered = Int(retentionField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        SettingsStore.shared.logRetentionRuns = entered > 0 ? entered : nil
        RunLogStore.shared.prune()
        settingsContainer.isHidden = true
        resizePopover()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        LoginItemManager.shared.setEnabled(sender.state == .on)
        // Reflect the actual on-disk state in case the change didn't take.
        launchAtLoginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
    }

    @objc private func clearLogs() {
        RunLogStore.shared.clearAll()
        if logsJob != nil, !logsContainer.isHidden {
            logsRuns = []
            refreshLogsPanel()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - JobRowDelegate

    func didToggleJob(_ job: CronJob, enabled: Bool) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx].isEnabled = enabled
        persistManagedJobs()
    }

    func didRunNow(_ job: CronJob) {
        // Runs silently; output is recorded as a run and viewable via the ☰
        // logs panel. If that panel is already open for this job, the
        // jobsDidChange notification refreshes it when the run finishes.
        SchedulerManager.shared.runNow(job)
    }

    // MARK: - Run Logs

    private static let runDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    func didViewLogs(_ job: CronJob) {
        logsJob = job
        logsRuns = RunLogStore.shared.runs(for: job)
        logsPage = 0
        logsExpanded = false
        selectedRunIndex = 0
        addFormContainer.isHidden = true
        settingsContainer.isHidden = true
        logsContainer.isHidden = false
        refreshLogsPanel()
    }

    @objc private func hideLogs() {
        logsContainer.isHidden = true
        logsJob = nil
        resizePopover()
    }

    private func refreshLogsPanel() {
        guard let job = logsJob else { return }
        let count = logsRuns.count
        logsTitleLabel.stringValue = "\(job.name) — \(count) run\(count == 1 ? "" : "s")"

        if logsRuns.isEmpty {
            logsSummaryLabel.stringValue = "No recorded runs yet"
            logsTerminal.string = ""
        } else {
            selectedRunIndex = min(selectedRunIndex, count - 1)
            let last = logsRuns[0]
            let viewing = logsRuns[selectedRunIndex]
            var summary = "Last run \(relativeString(last.date))\(last.isManual ? " (manual)" : "")"
            if selectedRunIndex != 0 {
                summary += " · viewing \(Self.runDateFormatter.string(from: viewing.date))"
            }
            logsSummaryLabel.stringValue = summary
            logsTerminal.string = (try? String(contentsOf: viewing.url, encoding: .utf8)) ?? "(could not read log)"
        }

        expandRunsBtn.isHidden = count <= 1
        expandRunsBtn.title = logsExpanded ? "Hide previous runs ▴" : "Show previous runs ▾"
        rebuildRunList()
        resizePopover()
    }

    private func rebuildRunList() {
        runListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let pageSize = 10
        let pageCount = max(1, (logsRuns.count + pageSize - 1) / pageSize)
        logsPage = min(logsPage, pageCount - 1)
        runListStack.isHidden = !logsExpanded
        paginationRow.isHidden = !logsExpanded || pageCount <= 1
        guard logsExpanded else { return }

        let start = logsPage * pageSize
        let end = min(start + pageSize, logsRuns.count)
        for i in start..<end {
            let run = logsRuns[i]
            let title = "\(Self.runDateFormatter.string(from: run.date))\(run.isManual ? "  (manual)" : "")"
            let btn = NSButton(title: title, target: self, action: #selector(selectRun(_:)))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.tag = i
            btn.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            btn.contentTintColor = i == selectedRunIndex ? .controlAccentColor : .labelColor
            runListStack.addArrangedSubview(btn)
        }
        pageLabel.stringValue = "Page \(logsPage + 1) of \(pageCount)"
        prevPageBtn.isEnabled = logsPage > 0
        nextPageBtn.isEnabled = logsPage < pageCount - 1
    }

    @objc private func selectRun(_ sender: NSButton) {
        selectedRunIndex = sender.tag
        refreshLogsPanel()
    }

    @objc private func toggleRunList() {
        logsExpanded.toggle()
        refreshLogsPanel()
    }

    @objc private func prevPage() {
        logsPage -= 1
        rebuildRunList()
        resizePopover()
    }

    @objc private func nextPage() {
        logsPage += 1
        rebuildRunList()
        resizePopover()
    }

    func didEditJob(_ job: CronJob) {
        showEditForm(for: job)
    }

    func didDeleteJob(_ job: CronJob) {
        if job.source == .external {
            SchedulerManager.shared.removeExternal(job)
            loadJobs()
            return
        }
        SchedulerManager.shared.deleteManaged(job)
        jobs.removeAll { $0.id == job.id }
        persistManagedJobs()
        rebuildJobList()
    }
}
