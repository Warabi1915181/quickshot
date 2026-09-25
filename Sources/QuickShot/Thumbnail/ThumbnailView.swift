import AppKit

/// Chrome + image for one thumbnail. Slim always-visible control bar.
@MainActor
final class ThumbnailView: NSView {
    private enum Metrics {
        static let padding: CGFloat = 8
        static let gap: CGFloat = 6
        static let controlsHeight: CGFloat = 28
        static let maxImageLongEdge: CGFloat = 200
        static let minContentWidth: CGFloat = 156
        static let cornerRadius: CGFloat = 12
    }

    private let effectView = NSVisualEffectView()
    private let imageView = ThumbnailImageView()
    private let controlsStack = NSStackView()
    private var imageHeightConstraint: NSLayoutConstraint!
    private var didSetupLayout = false

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDragRequested: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupChrome()
        setupImageView()
        setupControls()
        layoutContent(pixelSize: CGSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func contentSize(forPixelSize pixelSize: CGSize) -> CGSize {
        let imageSize = fittedImageSize(forPixelSize: pixelSize)
        return CGSize(
            width: max(imageSize.width + Metrics.padding * 2, Metrics.minContentWidth),
            height: imageSize.height + Metrics.gap + Metrics.controlsHeight + Metrics.padding * 2
        )
    }

    func update(image: NSImage, pixelSize: CGSize) {
        imageView.image = image
        layoutContent(pixelSize: pixelSize)
        needsLayout = true
    }

    // MARK: - Setup

    private func setupChrome() {
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Metrics.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupImageView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // Let the window's explicit size win over the image's point size.
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.onDragRequested = { [weak self] event in
            self?.onDragRequested?(event)
        }
        addSubview(imageView)
    }

    private func setupControls() {
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 4
        controlsStack.alignment = .centerY
        controlsStack.distribution = .equalSpacing
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsStack)

        controlsStack.addArrangedSubview(makeButton(
            symbol: "doc.on.doc",
            label: "Copy",
            action: #selector(copyAction)
        ))
        controlsStack.addArrangedSubview(makeButton(
            symbol: "arrow.down.to.line",
            label: "Save to Downloads",
            action: #selector(saveAction)
        ))
        controlsStack.addArrangedSubview(makeButton(
            symbol: "square.and.arrow.down",
            label: "Save As",
            action: #selector(saveAsAction)
        ))
        controlsStack.addArrangedSubview(makeButton(
            symbol: "pencil.tip.crop.circle",
            label: "Annotate",
            action: #selector(annotateAction)
        ))
        controlsStack.addArrangedSubview(makeButton(
            symbol: "xmark.circle",
            label: "Discard",
            action: #selector(discardAction)
        ))

    }

    private func layoutContent(pixelSize: CGSize) {
        let imageSize = Self.fittedImageSize(forPixelSize: pixelSize)
        if !didSetupLayout {
            didSetupLayout = true
            let height = imageView.heightAnchor.constraint(equalToConstant: imageSize.height)
            imageHeightConstraint = height
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
                height,
                controlsStack.topAnchor.constraint(
                    equalTo: imageView.bottomAnchor,
                    constant: Metrics.gap
                ),
                controlsStack.heightAnchor.constraint(equalToConstant: Metrics.controlsHeight),
                controlsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
                controlsStack.bottomAnchor.constraint(
                    equalTo: bottomAnchor,
                    constant: -Metrics.padding
                ),
                controlsStack.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor,
                    constant: Metrics.padding
                ),
                controlsStack.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor,
                    constant: -Metrics.padding
                )
            ])
        } else {
            imageHeightConstraint.constant = imageSize.height
        }
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

    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = ThumbnailButton()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.image = image?.withSymbolConfiguration(
            .init(pointSize: 11, weight: .regular)
        )
        button.bezelStyle = .smallSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: - Actions

    @objc private func copyAction() { onCopy?() }
    @objc private func saveAction() { onSave?() }
    @objc private func saveAsAction() { onSaveAs?() }
    @objc private func annotateAction() { onAnnotate?() }
    @objc private func discardAction() { onDiscard?() }
}

/// First-clickable button inside a non-activating panel.
private final class ThumbnailButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
