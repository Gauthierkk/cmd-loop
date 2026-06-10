import AppKit

protocol JobRowDelegate: AnyObject {
    func didToggleJob(_ job: CronJob, enabled: Bool)
    func didRunNow(_ job: CronJob)
    func didEditJob(_ job: CronJob)
    func didDeleteJob(_ job: CronJob)
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

        let nameLabel = NSTextField(labelWithString: job.name)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cronLabel = NSTextField(labelWithString: job.cronExpression)
        cronLabel.textColor = .secondaryLabelColor
        cronLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

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

        let runBtn = NSButton(title: "▶", target: self, action: #selector(runNowPressed))
        runBtn.bezelStyle = .inline
        runBtn.isBordered = false
        runBtn.font = .systemFont(ofSize: 10)

        let editBtn = NSButton(title: "✎", target: self, action: #selector(editPressed))
        editBtn.bezelStyle = .inline
        editBtn.isBordered = false
        editBtn.font = .systemFont(ofSize: 13)

        let deleteBtn = NSButton(title: "✕", target: self, action: #selector(deletePressed))
        deleteBtn.bezelStyle = .inline
        deleteBtn.isBordered = false
        deleteBtn.font = .systemFont(ofSize: 12)

        let hStack = NSStackView(views: [toggle, nameLabel, cronLabel, lastRunLabel, runBtn, editBtn, deleteBtn])
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 8
        hStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
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

    @objc private func editPressed() {
        delegate?.didEditJob(job)
    }

    @objc private func deletePressed() {
        delegate?.didDeleteJob(job)
    }
}
