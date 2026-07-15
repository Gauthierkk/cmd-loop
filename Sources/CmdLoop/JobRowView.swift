import AppKit

extension RelativeDateTimeFormatter {
    /// Shared abbreviated formatter — creating one per row/call is expensive.
    /// Not thread-safe; main-thread (UI) use only.
    static let abbreviated: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

protocol JobRowDelegate: AnyObject {
    func didToggleJob(_ job: CronJob, enabled: Bool)
    func didRunNow(_ job: CronJob)
    func didAdoptJob(_ job: CronJob)
    func didEditJob(_ job: CronJob)
    func didDeleteJob(_ job: CronJob)
    func didToggleDetail(_ job: CronJob)
}

class JobRowView: NSView {
    private let job: CronJob
    private weak var delegate: JobRowDelegate?
    /// Whether this job's detail panel is currently open (highlights the ☰ button).
    private let isDetailOpen: Bool
    /// Whether to reserve the adopt column. Set when the list contains any external
    /// entry, so the ⬇ button on external rows lines up with a blank slot on
    /// managed rows and the other action columns stay aligned across every row.
    private let showAdoptColumn: Bool

    init(job: CronJob, delegate: JobRowDelegate, isDetailOpen: Bool = false, showAdoptColumn: Bool = false) {
        self.job = job
        self.delegate = delegate
        self.isDetailOpen = isDetailOpen
        self.showAdoptColumn = showAdoptColumn
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
            toggle.toolTip = job.backend == .launchd
                ? "External launchd agent — enable/disable is managed in ~/Library/LaunchAgents"
                : "External cron entry — enable/disable is managed in your crontab"
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

        let lastRun = job.lastRunTime.map {
            RelativeDateTimeFormatter.abbreviated.localizedString(for: $0, relativeTo: Date())
        } ?? "never"
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
        let detailBtn = actionButton("☰", size: 12, tooltip: "Details & run logs", action: #selector(detailPressed))
        // Highlight the ☰ button while its detail panel is open.
        if isDetailOpen {
            detailBtn.contentTintColor = .controlAccentColor
            detailBtn.font = .boldSystemFont(ofSize: 13)
        }
        let deleteBtn = actionButton("✕", size: 12, tooltip: "Delete", action: #selector(deletePressed))

        // Adopt column: a ⬇ button on external rows, a blank same-width slot on
        // managed rows. Only present when some row needs it, so an all-managed list
        // isn't padded with an empty column.
        var views: [NSView] = [toggle, dot, nameLabel, lastRunLabel]
        if showAdoptColumn {
            if job.source == .external {
                views.append(actionButton("⬇", size: 12, tooltip: "Adopt: log each scheduled run to cmdloop", action: #selector(adoptPressed)))
            } else {
                let spacer = NSView()
                spacer.widthAnchor.constraint(equalToConstant: 20).isActive = true
                views.append(spacer)
            }
        }
        views.append(contentsOf: [runBtn, detailBtn, deleteBtn])

        let hStack = NSStackView(views: views)
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 8
        hStack.setCustomSpacing(10, after: toggle)
        hStack.setCustomSpacing(10, after: dot)
        hStack.setCustomSpacing(12, after: nameLabel)
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

    @objc private func adoptPressed() {
        delegate?.didAdoptJob(job)
    }

    @objc private func detailPressed() {
        delegate?.didToggleDetail(job)
    }

    @objc private func deletePressed() {
        delegate?.didDeleteJob(job)
    }
}
