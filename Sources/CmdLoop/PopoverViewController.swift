import AppKit

/// The popover's root controller: owns the job list and the shared layout, and
/// coordinates the three panels below it. Each panel's construction and actions
/// live in their own file: `+Form` (add/edit), `+Settings`, `+Logs` (detail).
class PopoverViewController: NSViewController, JobRowDelegate, NSTextFieldDelegate {
    // Job list
    var stackView: NSStackView!
    var jobs: [CronJob] = []

    // Add/edit form — built in PopoverViewController+Form.swift
    var addFormContainer: NSStackView!
    var nameField: NSTextField!
    var commandTextView: NSTextView!
    var cronField: NSTextField!
    var backendSelector: NSSegmentedControl!
    var launchdContainer: NSStackView!
    var launchdModeSelector: NSSegmentedControl!
    var minuteField, hourField, dayField, weekdayField, monthField: NSTextField!
    var calendarGroup: NSStackView!
    var intervalField: NSTextField!
    var intervalUnitSelector: NSSegmentedControl!
    var intervalRow: NSStackView!
    var scheduleReadOnlyLabel: NSTextField!
    var editingScheduleReadOnly = false
    var editingJob: CronJob?
    var externalEditHint: NSTextField!

    // Settings panel — built in PopoverViewController+Settings.swift
    var settingsContainer: NSStackView!
    var launchAtLoginCheckbox: NSButton!
    var autoAdoptCheckbox: NSButton!
    var retentionPopup: NSPopUpButton!

    // Detail/logs panel — built in PopoverViewController+Logs.swift
    var logsContainer: NSStackView!
    var logsTitleLabel: NSTextField!
    var logsFreqLabel: NSTextField!
    var releaseBtn: NSButton!
    var logsSummaryLabel: NSTextField!
    var logsTerminal: TerminalView!
    var expandRunsBtn: NSButton!
    var runListStack: NSStackView!
    var paginationRow: NSStackView!
    var pageLabel: NSTextField!
    var prevPageBtn: NSButton!
    var nextPageBtn: NSButton!
    var logsJob: CronJob?
    var logsRuns: [RunRecord] = []
    var logsPage = 0
    var logsExpanded = false
    var selectedRunIndex = 0

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

        buildAddForm()
        buildSettingsPanel()
        buildLogsPanel()

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

    func loadJobs() {
        jobs = SchedulerManager.shared.loadAllJobs()
        rebuildJobList()
    }

    /// Jobs cmdloop owns. External crontab entries are excluded so they're never
    /// persisted to config.json or rewritten with cmdloop markers.
    private var managedJobs: [CronJob] {
        jobs.filter { $0.source == .managed }
    }

    func persistManagedJobs() {
        let managed = managedJobs
        ConfigManager.shared.save(managed)
        SchedulerManager.shared.syncManaged(managed)
    }

    @objc func refreshJobs() {
        loadJobs()
        if let job = logsJob, !logsContainer.isHidden {
            logsRuns = RunLogStore.shared.runs(for: job)
            refreshLogsPanel()
        }
    }

    func rebuildJobList() {
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
                let detailOpen = !logsContainer.isHidden && logsJob?.id == job.id
                let row = JobRowView(job: job, delegate: self, isDetailOpen: detailOpen)
                stackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }
        resizePopover()
    }

    func resizePopover() {
        let width = desiredWidth()
        // Set width first so height is measured against the final width (the
        // multi-line command box and terminals wrap at that width).
        popover?.contentSize.width = width
        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        let newHeight = min(fittingSize.height, PopoverLayout.maxHeight)
        popover?.contentSize = NSSize(width: width, height: newHeight)
    }

    /// Width that fits the longest job name plus the fixed row chrome, clamped to
    /// the popover's min/max so short names don't cramp the panels and long names
    /// don't make it unwieldy.
    private func desiredWidth() -> CGFloat {
        // Any open panel (add/edit form, settings, or the detail terminal) uses a
        // fixed comfortable width so its content isn't cropped by the narrower
        // name-fit width the collapsed job list uses.
        if !logsContainer.isHidden || !addFormContainer.isHidden || !settingsContainer.isHidden {
            return PopoverLayout.panelWidth
        }
        let nameFont = NSFont.systemFont(ofSize: 13)
        let widestName = jobs
            .map { ($0.name as NSString).size(withAttributes: [.font: nameFont]).width }
            .max() ?? 0
        let target = ceil(widestName) + PopoverLayout.rowChromeWidth
        return min(max(target, PopoverLayout.minWidth), PopoverLayout.maxWidth)
    }

    /// Closes the detail panel and clears its row's ☰ highlight. The ☰ should
    /// only be lit while that job's detail panel is actually visible.
    func hideLogsPanel() {
        guard !logsContainer.isHidden else { return }
        logsContainer.isHidden = true
        logsJob = nil
        rebuildJobList()
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
