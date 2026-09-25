import AppKit
import QuickShotCore

/// Selectable, non-editable recognized text. Edits are out of scope for v1;
/// Copy / Return use the as-recognized result from `OCRReviewState`.
@MainActor
final class OCRReviewTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        usesFindBar = false
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textContainerInset = NSSize(width: 8, height: 8)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            onReturn?()
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        onReturn?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class OCRReviewView: NSView {
    var onCopy: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Recognized Text")
    private let textView = OCRReviewTextView(frame: .zero, textContainer: nil)
    private let scrollView = NSScrollView()
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)

    private let emptyPlaceholder = "(No text found)"
    private(set) var hasCopyableText = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with review: OCRReviewState) {
        let raw = review.result.text
        let isEmpty = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasCopyableText = !isEmpty
        textView.string = isEmpty ? emptyPlaceholder : raw
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = isEmpty ? .secondaryLabelColor : .labelColor
        copyButton.isEnabled = hasCopyableText
    }

    func focusText() {
        window?.makeFirstResponder(textView)
    }

    private func setUp() {
        wantsLayer = true

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Recognized text")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autohidesScrollers = true

        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalentModifierMask = []
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityLabel("Close")

        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = []
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.setAccessibilityLabel("Copy")

        textView.onReturn = { [weak self] in self?.handleReturn() }
        textView.onEscape = { [weak self] in self?.handleEscape() }

        for view in [titleLabel, scrollView, closeButton, copyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scrollView.heightAnchor.constraint(equalToConstant: 160),
            scrollView.widthAnchor.constraint(equalToConstant: 360),

            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            copyButton.topAnchor.constraint(greaterThanOrEqualTo: scrollView.bottomAnchor, constant: 12),

            closeButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
        ])
    }

    private func handleReturn() {
        if hasCopyableText {
            onCopy?()
        } else {
            onDismiss?()
        }
    }

    private func handleEscape() {
        onDismiss?()
    }

    @objc private func copyClicked() {
        handleReturn()
    }

    @objc private func closeClicked() {
        handleEscape()
    }
}
