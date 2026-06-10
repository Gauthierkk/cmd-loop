import AppKit

/// Shared dimensions for the popover so every panel sizes against the same page.
enum PopoverLayout {
    static let width: CGFloat = 440
    static let maxHeight: CGFloat = 520
    /// Terminals span this fraction of the popover width, centered.
    static let terminalWidthRatio: CGFloat = 0.8
}

/// A read-only, terminal-styled output view shared by every panel that shows
/// command output, plus a copy button pinned to the top-right corner that copies
/// the full contents to the clipboard. Width is set by the host (80% of the
/// popover, centered); height is fixed at exactly 10 text lines so every
/// terminal is identical.
final class TerminalView: NSView {

    private let textView = NSTextView()
    private let copyButton = NSButton()

    var string: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    func append(_ text: String) {
        textView.string += text
    }

    func scrollToEnd() {
        textView.scrollToEndOfDocument(nil)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.font = font
        textView.isEditable = false
        textView.isRichText = false
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        textView.textColor = .white
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The terminal floats centered in its panel, so round its corners.
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy all output")
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.contentTintColor = .white
        copyButton.toolTip = "Copy all output"
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(copyButton)

        // Fixed height of exactly 10 text lines (plus the vertical text insets).
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let tenLines = (lineHeight * 10).rounded(.up) + textView.textContainerInset.height * 2

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: tenLines),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            // Inset past the vertical scroller so the button never overlaps it.
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
        // Brief checkmark as confirmation, then restore the copy glyph.
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyButton.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy all output")
            self?.copyButton.contentTintColor = .white
        }
    }
}
