import AppKit

protocol JobRowDelegate: AnyObject {
    func didToggleJob(_ job: CronJob, enabled: Bool)
    func didRunNow(_ job: CronJob)
    func didEditJob(_ job: CronJob)
    func didDeleteJob(_ job: CronJob)
    func didViewLogs(_ job: CronJob)
}

class JobRowView: NSView {
    private let job: CronJob
    private weak var delegate: JobRowDelegate?

    init(job: CronJob, delegate: JobRowDelegate) {
        self.job = job
        self.delegate = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let toggle = NSSwitch()
        toggle.state = job.isEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.controlSize = .mini
        // External entries aren't owned by cmdloop, so enabling/disabling them isn't
        // tracked. Renaming, running, and deleting still work.
        if job.source == .external {
            toggle.isEnabled = false
            toggle.toolTip = "External cron entry — enable/disable is managed in your crontab"
        }

        // Status dot: blackish when the job has never run this session, pulsing
        // green while running, solid green after a clean exit, red on failure.
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let isRunning = CrontabManager.shared.runningJobIDs.contains(job.id)
        let status = CrontabManager.shared.runtimeStatuses[job.id] ?? job.lastRunStatus
        if isRunning {
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.toolTip = "Running…"
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "pulse")
        } else {
            switch status {
            case .success:
                dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                dot.toolTip = "Last run succeeded"
            case .failure:
                dot.layer?.backgroundColor = NSColor.systemRed.cgColor
                dot.toolTip = "Last run failed"
            case nil:
                dot.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
                dot.toolTip = "No runs yet"
            }
        }

        // Columns: the name flexes to fill leftover space while every other
        // column has a fixed width, so cron expressions, last-run times, and the
        // action buttons line up vertically across rows.
        let nameLabel = NSTextField(labelWithString: job.name)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let cronLabel = NSTextField(labelWithString: job.cronExpression)
        cronLabel.textColor = .secondaryLabelColor
        cronLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cronLabel.lineBreakMode = .byTruncatingTail
        cronLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let lastRun: String
        if let time = job.lastRunTime {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            lastRun = formatter.localizedString(for: time, relativeTo: Date())
        } else {
            lastRun = "never"
        }
        let lastRunLabel = NSTextField(labelWithString: lastRun)
        lastRunLabel.textColor = .tertiaryLabelColor
        lastRunLabel.font = .systemFont(ofSize: 10)
        lastRunLabel.alignment = .right
        lastRunLabel.lineBreakMode = .byClipping
        lastRunLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        func actionButton(_ title: String, size: CGFloat, tooltip: String, action: Selector) -> NSButton {
            let btn = NSButton(title: title, target: self, action: action)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.font = .systemFont(ofSize: size)
            btn.alignment = .center
            btn.toolTip = tooltip
            btn.widthAnchor.constraint(equalToConstant: 20).isActive = true
            return btn
        }

        let runBtn = actionButton("▶", size: 10, tooltip: "Run now", action: #selector(runNowPressed))
        let logsBtn = actionButton("☰", size: 12, tooltip: "View run logs", action: #selector(logsPressed))
        let editBtn = actionButton("✎", size: 13, tooltip: "Edit", action: #selector(editPressed))
        let deleteBtn = actionButton("✕", size: 12, tooltip: "Delete", action: #selector(deletePressed))

        let hStack = NSStackView(views: [toggle, dot, nameLabel, cronLabel, lastRunLabel, runBtn, logsBtn, editBtn, deleteBtn])
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 8
        hStack.setCustomSpacing(10, after: toggle)
        hStack.setCustomSpacing(10, after: dot)
        hStack.setCustomSpacing(12, after: nameLabel)
        hStack.setCustomSpacing(12, after: cronLabel)
        hStack.setCustomSpacing(12, after: lastRunLabel)
        hStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        hStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: topAnchor),
            hStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            hStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        delegate?.didToggleJob(job, enabled: sender.state == .on)
    }

    @objc private func runNowPressed() {
        delegate?.didRunNow(job)
    }

    @objc private func logsPressed() {
        delegate?.didViewLogs(job)
    }

    @objc private func editPressed() {
        delegate?.didEditJob(job)
    }

    @objc private func deletePressed() {
        delegate?.didDeleteJob(job)
    }
}
