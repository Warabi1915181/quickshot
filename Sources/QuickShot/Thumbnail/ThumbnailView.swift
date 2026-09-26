import AppKit

/// Floating card for one capture: image alone until the pointer arrives, then a
/// translucent action scrim (stories 19, 26–28, 32, 33).
@MainActor
final class ThumbnailView: NSView {
    private enum Metrics {
        /// Clearance around the card so its drop shadow is not clipped by the panel.
        static let shadowInset: CGFloat = 14
        static let cornerRadius: CGFloat = 10
        static let maxImageLongEdge: CGFloat = 200
        /// Icon buttons inset from their card corner.
        static let cornerInset: CGFloat = 6
        /// Every control is the same round chip, whether it holds a glyph or a word.
        static let chipSide: CGFloat = 24
        static let chipRadius: CGFloat = 12
        /// Horizontal breathing room inside a text chip.
        static let chipPadding: CGFloat = 10
        static let actionSpacing: CGFloat = 6
        static let scrimAlpha: CGFloat = 0.5
        /// Smallest card that still holds the whole overlay without collisions:
        /// two corner chips down the trailing edge, and the centred pair of text
        /// chips between the leading and trailing ones. Thinner captures letterbox.
        static let minCardSize = CGSize(width: 176, height: 62)
    }

    private let cardView = NSView()
    private let imageView = ThumbnailImageView()
    private let overlayView = ThumbnailScrimView()
    private let centerStack = NSStackView()
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private var overlayVisible = false
    private var voiceOverObservation: NSKeyValueObservation?

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDragRequested: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupCard()
        setupImageView()
        setupOverlay()
        setupVoiceOverObserver()
    }

    deinit {
        voiceOverObservation?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Panel size: the card, which is the fitted image floored at the overlay's
    /// minimum, plus room for the card's shadow.
    static func contentSize(forPixelSize pixelSize: CGSize) -> CGSize {
        let image = fittedImageSize(forPixelSize: pixelSize)
        return CGSize(
            width: max(image.width, Metrics.minCardSize.width) + Metrics.shadowInset * 2,
            height: max(image.height, Metrics.minCardSize.height) + Metrics.shadowInset * 2
        )
    }

    func update(image: NSImage) {
        imageView.image = image
        needsLayout = true
    }

    // MARK: - Setup

    private func setupCard() {
        cardView.wantsLayer = true
        // No masksToBounds: the shadow has to escape the rounded corners.
        cardView.layer?.masksToBounds = false
        cardView.layer?.cornerRadius = Metrics.cornerRadius
        cardView.layer?.borderWidth = 0.5
        cardView.layer?.borderColor = NSColor.separatorColor.cgColor
        cardView.layer?.shadowColor = NSColor.black.cgColor
        cardView.layer?.shadowOpacity = 0.4
        cardView.layer?.shadowRadius = 9
        cardView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.shadowInset),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.shadowInset),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.shadowInset),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.shadowInset)
        ])
    }

    private func setupImageView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Metrics.cornerRadius
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // Let the panel's explicit size win over the image's point size.
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.onDragRequested = { [weak self] event in
            self?.onDragRequested?(event)
        }
        cardView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor)
        ])
    }

    private func setupOverlay() {
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(Metrics.scrimAlpha)
            .cgColor
        overlayView.layer?.cornerRadius = Metrics.cornerRadius
        overlayView.layer?.masksToBounds = true
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: cardView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor)
        ])

        let cancel = makeIconChip(symbol: "xmark", label: "Cancel", action: #selector(discardAction))
        let annotate = makeIconChip(
            symbol: "pencil.tip.crop.circle",
            label: "Annotate",
            action: #selector(annotateAction)
        )
        let saveAs = makeIconChip(
            symbol: "square.and.arrow.down",
            label: "Save As",
            action: #selector(saveAsAction)
        )

        centerStack.orientation = .horizontal
        centerStack.spacing = Metrics.actionSpacing
        centerStack.alignment = .centerY
        centerStack.distribution = .equalSpacing
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.addArrangedSubview(makeTextChip(title: "Copy", action: #selector(copyAction)))
        centerStack.addArrangedSubview(makeTextChip(title: "Save", action: #selector(saveAction)))
        overlayView.addSubview(centerStack)
        overlayView.addSubview(cancel)
        overlayView.addSubview(annotate)
        overlayView.addSubview(saveAs)

        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: Metrics.cornerInset),
            cancel.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: Metrics.cornerInset),
            annotate.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -Metrics.cornerInset),
            annotate.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: Metrics.cornerInset),
            saveAs.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -Metrics.cornerInset),
            saveAs.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: -Metrics.cornerInset),
            centerStack.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor)
        ])

        // Hidden means no hit-testing either, so the chips cannot be clicked
        // while they are invisible.
        overlayView.isHidden = true
    }

    private func setupVoiceOverObserver() {
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshOverlay() }
        }
        refreshOverlay()
    }

    static func fittedImageSize(forPixelSize pixelSize: CGSize) -> CGSize {
        let width = max(pixelSize.width, 1)
        let height = max(pixelSize.height, 1)
        let aspect = width / height
        var fitted: CGSize
        if width >= height {
            fitted = CGSize(width: Metrics.maxImageLongEdge, height: Metrics.maxImageLongEdge / aspect)
        } else {
            fitted = CGSize(width: Metrics.maxImageLongEdge * aspect, height: Metrics.maxImageLongEdge)
        }
        fitted.width = max(fitted.width, 48)
        fitted.height = max(fitted.height, 32)
        return fitted
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cardView.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshOverlay()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        refreshOverlay()
    }

    private func refreshOverlay() {
        // VoiceOver cannot hover, so the controls stay revealed for it.
        setOverlayVisible(pointerInside || NSWorkspace.shared.isVoiceOverEnabled)
    }

    private func setOverlayVisible(_ visible: Bool) {
        guard visible != overlayVisible else { return }
        overlayVisible = visible
        if visible {
            overlayView.isHidden = false
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            self.overlayView.animator().alphaValue = visible ? 1 : 0
        }
        guard !visible else { return }
        // Hidden also means not hit-testable, so the chips cannot be clicked
        // once they have faded out. Deferred so a re-hover wins the race.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.overlayVisible else { return }
                self.overlayView.isHidden = true
            }
        }
    }

    // MARK: - Controls

    private func makeIconChip(symbol: String, label: String, action: Selector) -> ThumbnailChipButton {
        let chip = makeChip(action: action, accessibilityLabel: label, tooltip: label)
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        chip.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        chip.imagePosition = .imageOnly
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: Metrics.chipSide),
            chip.heightAnchor.constraint(equalToConstant: Metrics.chipSide)
        ])
        return chip
    }

    private func makeTextChip(title: String, action: Selector) -> ThumbnailChipButton {
        let tooltip = title == "Save" ? "Save to Downloads" : title
        let chip = makeChip(action: action, accessibilityLabel: title, tooltip: tooltip)
        // A label rather than the button's own title: it gives the chip exact
        // padding and keeps the text white whatever the appearance.
        let label = PassThroughLabel(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Metrics.chipPadding),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -Metrics.chipPadding),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.widthAnchor.constraint(
                equalToConstant: label.intrinsicContentSize.width + Metrics.chipPadding * 2
            ),
            chip.heightAnchor.constraint(equalToConstant: Metrics.chipSide)
        ])
        return chip
    }

    private func makeChip(
        action: Selector,
        accessibilityLabel: String,
        tooltip: String
    ) -> ThumbnailChipButton {
        let chip = ThumbnailChipButton(cornerRadius: Metrics.chipRadius)
        chip.target = self
        chip.action = action
        chip.setAccessibilityLabel(accessibilityLabel)
        chip.toolTip = tooltip
        chip.translatesAutoresizingMaskIntoConstraints = false
        return chip
    }

    // MARK: - Actions

    @objc private func copyAction() { onCopy?() }
    @objc private func saveAction() { onSave?() }
    @objc private func saveAsAction() { onSaveAs?() }
    @objc private func annotateAction() { onAnnotate?() }
    @objc private func discardAction() { onDiscard?() }
}

/// Overlay control drawn by this file rather than by AppKit's bezel: a thumbnail
/// panel never becomes key, and the standard bezels all but vanish against the
/// scrim in a non-key window. Dark pill, white content, no appearance surprises.
private final class ThumbnailChipButton: NSButton {
    private enum Fill {
        static let resting: CGFloat = 0.28
        static let hovering: CGFloat = 0.18
        static let pressing: CGFloat = 0.28
        static let stroke: CGFloat = 0.22
        static let highlightedStroke: CGFloat = 0.45
    }

    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(Fill.stroke).cgColor
        refreshFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The chip is a plain dark pill with a hairline, not an ornamented control,
    /// so its frame is its alignment rect. Without this the cell's bezel insets
    /// pad the frame and push every constraint pinned to the chip off by a few
    /// points.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refreshFill() {
        let highlighted = isEnabled && (hovered || pressed)
        let fill = highlighted
            ? NSColor.white.withAlphaComponent(pressed ? Fill.pressing : Fill.hovering)
            : NSColor.black.withAlphaComponent(Fill.resting)
        let stroke = highlighted ? Fill.highlightedStroke : Fill.stroke
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(stroke).cgColor
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshFill()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refreshFill()
        super.mouseDown(with: event)
        pressed = false
        refreshFill()
    }
}

/// Scrim that swallows nothing: its chips are clickable, the scrim itself hands
/// the pointer back to the image underneath so dragging still works anywhere.
private final class ThumbnailScrimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Label that leaves hit-testing to the chip holding it.
private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Image surface that distinguishes click vs drag (3pt threshold) for story 30.
final class ThumbnailImageView: NSImageView {
    var onDragRequested: ((NSEvent) -> Void)?

    private var mouseDownPoint: NSPoint?
    private let dragThreshold: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y
        guard (dx * dx + dy * dy) >= dragThreshold * dragThreshold else { return }
        mouseDownPoint = nil
        onDragRequested?(event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }
}
