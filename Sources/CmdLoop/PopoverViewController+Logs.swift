import AppKit

/// The detail panel opened by a row's ☰ button: run summary, terminal output,
/// and the expandable, paginated list of previous runs.
extension PopoverViewController {

    /// Builds the panel's views into `logsContainer` (hidden by default).
    /// Header reads: "<Name> : N runs · <english frequency>" with an edit button.
    func buildLogsPanel() {
        logsTitleLabel = NSTextField(labelWithString: "")
        logsTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        logsTitleLabel.lineBreakMode = .byTruncatingTail

        logsFreqLabel = NSTextField(labelWithString: "")
        logsFreqLabel.font = .systemFont(ofSize: 12)
        logsFreqLabel.textColor = .secondaryLabelColor
        logsFreqLabel.lineBreakMode = .byTruncatingTail
        logsFreqLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let editLogsBtn = NSButton(title: "✎ Edit", target: self, action: #selector(editLogsJob))
        editLogsBtn.bezelStyle = .toolbar
        editLogsBtn.font = .systemFont(ofSize: 11)

        let logsHeader = NSStackView(views: [logsTitleLabel, logsFreqLabel, NSView(), editLogsBtn])
        logsHeader.orientation = .horizontal
        logsHeader.spacing = 6
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

    // MARK: - Panel state

    private static let runDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func relativeString(_ date: Date) -> String {
        RelativeDateTimeFormatter.abbreviated.localizedString(for: date, relativeTo: Date())
    }

    func didToggleDetail(_ job: CronJob) {
        // Re-clicking the ☰ of the job whose detail is open closes it.
        if !logsContainer.isHidden, logsJob?.id == job.id {
            hideLogsPanel()
            return
        }
        logsJob = job
        logsRuns = RunLogStore.shared.runs(for: job)
        logsPage = 0
        logsExpanded = false
        selectedRunIndex = 0
        addFormContainer.isHidden = true
        settingsContainer.isHidden = true
        logsContainer.isHidden = false
        refreshLogsPanel()
        rebuildJobList() // refresh the ☰ highlight on the rows
    }

    @objc private func editLogsJob() {
        guard let job = logsJob else { return }
        showEditForm(for: job) // hides the detail panel and clears the ☰ highlight
    }

    func refreshLogsPanel() {
        guard let job = logsJob else { return }
        let count = logsRuns.count
        logsTitleLabel.stringValue = "\(job.name) : \(count) run\(count == 1 ? "" : "s")"
        logsFreqLabel.stringValue = "· \(job.schedule.englishFrequency)"

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
}
