import AppKit
import QuickShotCore

/// Top chrome: tools, style, undo/redo, output actions.
/// Crop Apply/Cancel appear while a crop marquee is pending.
@MainActor
final class AnnotatorToolbar: NSView {
    var onSelectTool: ((AnnotationTool) -> Void)?
    var onChangeColor: ((RGBAColor) -> Void)?
    var onChangeStrokeWidth: ((Double) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onOCR: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onCancelCrop: (() -> Void)?

    static let preferredHeight: CGFloat = 52

    private let effectView = NSVisualEffectView()
    private let toolControl = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "Width")
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let cropBox = NSStackView()
    private let applyCropButton = NSButton()
    private let cancelCropButton = NSButton()
    private let ocrButton = NSButton()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let saveAsButton = NSButton()

    private static let tools: [AnnotationTool] = [
        .arrow, .text, .rectangle, .ellipse, .highlight, .blur, .crop
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func setState(
        selectedTool: AnnotationTool,
        color: RGBAColor,
        strokeWidth: Double,
        canUndo: Bool,
        canRedo: Bool,
        cropPending: Bool
    ) {
        if let index = Self.tools.firstIndex(of: selectedTool) {
            toolControl.selectedSegment = index
        }
        if colorWell.color != color.nsColor {
            colorWell.color = color.nsColor
        }
        if widthSlider.doubleValue != strokeWidth {
            widthSlider.doubleValue = strokeWidth
        }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        cropBox.isHidden = !cropPending
        // Key equivalents only while the crop marquee is live (avoid stealing Return/Escape).
        applyCropButton.keyEquivalent = cropPending ? "\r" : ""
        cancelCropButton.keyEquivalent = cropPending ? "\u{1b}" : ""
    }

    // MARK: - Build

    private func build() {
        wantsLayer = true

        effectView.material = .headerView
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(row)

        configureTools()
        configureStyle()
        configureHistory()
        configureCropActions()
        configureOutput()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(toolControl)
        row.addArrangedSubview(separator())
        row.addArrangedSubview(colorWell)
        row.addArrangedSubview(widthLabel)
        row.addArrangedSubview(widthSlider)
        row.addArrangedSubview(separator())
        row.addArrangedSubview(undoButton)
        row.addArrangedSubview(redoButton)
        row.addArrangedSubview(cropBox)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(ocrButton)
        row.addArrangedSubview(copyButton)
        row.addArrangedSubview(saveButton)
        row.addArrangedSubview(saveAsButton)

        cropBox.isHidden = true

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            row.topAnchor.constraint(equalTo: effectView.topAnchor),
            row.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            heightAnchor.constraint(equalToConstant: Self.preferredHeight),
            widthSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    private func configureTools() {
        toolControl.segmentCount = Self.tools.count
        toolControl.trackingMode = .selectOne
        for (index, tool) in Self.tools.enumerated() {
            toolControl.setImage(Self.symbol(for: tool), forSegment: index)
            toolControl.setWidth(32, forSegment: index)
            toolControl.setLabel(Self.accessibilityLabel(for: tool), forSegment: index)
        }
        toolControl.toolTip = "Annotation tools (1–7)"
        toolControl.target = self
        toolControl.action = #selector(toolChanged(_:))
        toolControl.setAccessibilityLabel("Annotation tool")
    }

    private func configureStyle() {
        colorWell.color = RGBAColor.red.nsColor
        colorWell.supportsAlpha = false
        colorWell.toolTip = "Stroke color"
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.setAccessibilityLabel("Stroke color")

        widthLabel.font = .systemFont(ofSize: 11)
        widthLabel.textColor = .secondaryLabelColor
        widthLabel.setAccessibilityLabel("Stroke width")

        widthSlider.toolTip = "Stroke width"
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        widthSlider.setAccessibilityLabel("Stroke width")
    }

    private func configureHistory() {
        configureIconButton(undoButton, symbol: "arrow.uturn.backward", label: "Undo", action: #selector(undoTapped))
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", label: "Redo", action: #selector(redoTapped))
    }

    private func configureCropActions() {
        applyCropButton.title = "Apply"
        applyCropButton.bezelStyle = .rounded
        applyCropButton.target = self
        applyCropButton.action = #selector(applyCropTapped)
        applyCropButton.keyEquivalent = "\r"
        applyCropButton.setAccessibilityLabel("Apply crop")

        cancelCropButton.title = "Cancel"
        cancelCropButton.bezelStyle = .rounded
        cancelCropButton.target = self
        cancelCropButton.action = #selector(cancelCropTapped)
        cancelCropButton.keyEquivalent = "\u{1b}"
        cancelCropButton.setAccessibilityLabel("Cancel crop")

        cropBox.orientation = .horizontal
        cropBox.spacing = 6
        cropBox.addArrangedSubview(applyCropButton)
        cropBox.addArrangedSubview(cancelCropButton)
    }

    private func configureOutput() {
        configureTextButton(ocrButton, title: "OCR", label: "OCR", action: #selector(ocrTapped))
        configureTextButton(copyButton, title: "Copy", label: "Copy", action: #selector(copyTapped))
        configureTextButton(saveButton, title: "Save", label: "Save", action: #selector(saveTapped))
        configureTextButton(saveAsButton, title: "Save As…", label: "Save As", action: #selector(saveAsTapped))
    }

    private func configureIconButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func configureTextButton(_ button: NSButton, title: String, label: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private static func symbol(for tool: AnnotationTool) -> NSImage? {
        let name: String
        switch tool {
        case .arrow: name = "arrow.up.right"
        case .text: name = "textformat"
        case .rectangle: name = "rectangle"
        case .ellipse: name = "oval"
        case .highlight: name = "highlighter"
        case .blur: name = "camera.filters"
        case .crop: name = "crop"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel(for: tool))
    }

    private static func accessibilityLabel(for tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: return "Arrow tool"
        case .text: return "Text tool"
        case .rectangle: return "Rectangle tool"
        case .ellipse: return "Ellipse tool"
        case .highlight: return "Highlight tool"
        case .blur: return "Blur tool"
        case .crop: return "Crop tool"
        }
    }

    // MARK: - Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard Self.tools.indices.contains(index) else { return }
        onSelectTool?(Self.tools[index])
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        onChangeColor?(RGBAColor(sender.color))
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        onChangeStrokeWidth?(sender.doubleValue)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func applyCropTapped() { onApplyCrop?() }
    @objc private func cancelCropTapped() { onCancelCrop?() }
    @objc private func ocrTapped() { onOCR?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func saveAsTapped() { onSaveAs?() }
}
