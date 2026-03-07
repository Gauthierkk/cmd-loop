import AppKit

class PopoverViewController: NSViewController, JobRowDelegate {
    private var stackView: NSStackView!
    private var addFormContainer: NSStackView!
    private var nameField: NSTextField!
    private var commandTextView: NSTextView!
    private var cronField: NSTextField!
    private var outputContainer: NSStackView!
    private var outputTextView: NSTextView!
    private var jobs: [CronJob] = []
    private var editingJobId: UUID?
    weak var popover: NSPopover?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
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
        stackView.spacing = 1
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 4, right: 0)
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

        addFormContainer = NSStackView(views: [nameField, cronField, cmdScroll, buttonRow])
        addFormContainer.orientation = .vertical
        addFormContainer.alignment = .width
        addFormContainer.spacing = 6
        addFormContainer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        addFormContainer.isHidden = true
        addFormContainer.translatesAutoresizingMaskIntoConstraints = false

        // Output panel (hidden by default)
        outputTextView = NSTextView()
        outputTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputTextView.isEditable = false
        outputTextView.isRichText = false
        outputTextView.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        outputTextView.textColor = .white
        outputTextView.textContainerInset = NSSize(width: 6, height: 6)

        let outputScroll = NSScrollView()
        outputScroll.documentView = outputTextView
        outputScroll.hasVerticalScroller = true
        outputScroll.borderType = .noBorder
        outputScroll.translatesAutoresizingMaskIntoConstraints = false
        outputScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        outputTextView.minSize = NSSize(width: 0, height: 120)
        outputTextView.isVerticallyResizable = true
        outputTextView.isHorizontallyResizable = false
        outputTextView.autoresizingMask = [.width]
        outputTextView.textContainer?.widthTracksTextView = true

        let closeOutputBtn = NSButton(title: "✕ Close", target: self, action: #selector(hideOutput))
        closeOutputBtn.bezelStyle = .toolbar
        closeOutputBtn.font = .systemFont(ofSize: 11)

        let outputHeader = NSStackView(views: [NSView(), closeOutputBtn])
        outputHeader.orientation = .horizontal
        outputHeader.spacing = 4
        outputHeader.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 8)

        outputContainer = NSStackView(views: [outputHeader, outputScroll])
        outputContainer.orientation = .vertical
        outputContainer.alignment = .width
        outputContainer.spacing = 0
        outputContainer.isHidden = true
        outputContainer.translatesAutoresizingMaskIntoConstraints = false

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Add button
        let addBtn = NSButton(title: "+ Add Command", target: self, action: #selector(showAddForm))
        addBtn.bezelStyle = .toolbar
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        // Quit button
        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitBtn.bezelStyle = .toolbar
        quitBtn.translatesAutoresizingMaskIntoConstraints = false

        let clearLogsBtn = NSButton(title: "Clear Logs", target: self, action: #selector(clearLogs))
        clearLogsBtn.bezelStyle = .toolbar
        clearLogsBtn.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [addBtn, clearLogsBtn, quitBtn])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 12
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)

        // Main layout
        let mainStack = NSStackView(views: [stackView, outputContainer, addFormContainer, separator, bottomRow])
        mainStack.orientation = .vertical
        mainStack.spacing = 0
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func loadJobs() {
        jobs = CrontabManager.shared.loadAllJobs()
        rebuildJobList()
    }

    @objc private func refreshJobs() {
        loadJobs()
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
        let maxHeight: CGFloat = 500
        let newHeight = min(fittingSize.height, maxHeight)
        popover?.contentSize = NSSize(width: 420, height: newHeight)
    }

    @objc private func showAddForm() {
        editingJobId = nil
        addFormContainer.isHidden = false
        nameField.stringValue = ""
        cronField.stringValue = ""
        commandTextView.string = ""
        cronField.backgroundColor = .controlBackgroundColor
        resizePopover()
        view.window?.makeFirstResponder(nameField)
    }

    private func showEditForm(for job: CronJob) {
        editingJobId = job.id
        addFormContainer.isHidden = false
        nameField.stringValue = job.name
        cronField.stringValue = job.cronExpression
        commandTextView.string = job.command
        cronField.backgroundColor = .controlBackgroundColor
        resizePopover()
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func hideAddForm() {
        addFormContainer.isHidden = true
        editingJobId = nil
        resizePopover()
    }

    @objc private func saveNewJob() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let command = commandTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let cron = cronField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !command.isEmpty, !cron.isEmpty else { return }

        guard (try? CronParser(cron)) != nil else {
            cronField.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15)
            return
        }

        if let editId = editingJobId, let idx = jobs.firstIndex(where: { $0.id == editId }) {
            jobs[idx].name = name
            jobs[idx].command = command
            jobs[idx].cronExpression = cron
        } else {
            let job = CronJob(name: name, command: command, cronExpression: cron)
            jobs.append(job)
        }
        editingJobId = nil
        ConfigManager.shared.save(jobs)
        CrontabManager.shared.sync(jobs)
        rebuildJobList()
        addFormContainer.isHidden = true
        resizePopover()
    }

    @objc private func clearLogs() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmd-loop/logs")
        if let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "log" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - JobRowDelegate

    func didToggleJob(_ job: CronJob, enabled: Bool) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx].isEnabled = enabled
        ConfigManager.shared.save(jobs)
        CrontabManager.shared.sync(jobs)
    }

    func didRunNow(_ job: CronJob) {
        outputTextView.string = "$ \(job.command)\n"
        outputContainer.isHidden = false
        resizePopover()
        CrontabManager.shared.runNow(job) { [weak self] text in
            guard let self else { return }
            self.outputTextView.string += text
            self.outputTextView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func hideOutput() {
        outputContainer.isHidden = true
        resizePopover()
    }

    func didEditJob(_ job: CronJob) {
        showEditForm(for: job)
    }

    func didDeleteJob(_ job: CronJob) {
        jobs.removeAll { $0.id == job.id }
        ConfigManager.shared.save(jobs)
        CrontabManager.shared.sync(jobs)
        rebuildJobList()
    }
}
