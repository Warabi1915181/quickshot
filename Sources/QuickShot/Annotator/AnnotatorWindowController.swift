import AppKit
import QuickShotCore

/// Annotator window owner. SHELL binds the callbacks to `CaptureWorkflow.dispatch`.
///
/// Call `bind(workflow:)` before `show()` — every edit (and Copy / Save / Save As / OCR)
/// pushes the live document via `AnnotatorEditor.sync(to:)` so flatten sees marks (story 42).
/// Copy / Save otherwise only notify; the workflow flattens via `ImageRendering` and owns teardown.
///
/// Save As presents `NSSavePanel` here (story 28) and hands the URL to `onSaveAs`.
/// Close without output calls `onClose` so the pending capture returns to its
/// thumbnail (story 34); programmatic `close()` does not.
@MainActor
public final class AnnotatorWindowController: NSWindowController, NSWindowDelegate {
    /// QuickShotCore.AnnotatorEditor — local undo/redo (story 41).
    private var editor: AnnotatorEditor
    private weak var workflow: CaptureWorkflow?
    private let renderer: any ImageRendering
    private let canvas: AnnotatorCanvasView
    private let toolbar: AnnotatorToolbar

    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onSaveAs: (URL) -> Void
    private let onClose: () -> Void
    private let onOCR: () -> Void

    private var isProgrammaticClose = false
    private var activeTool: AnnotationTool = .arrow
    private var strokeColor: RGBAColor = .red
    private var strokeWidth: Double = 4

    public init(
        state: AnnotatorState,
        renderer: any ImageRendering,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onSaveAs: @escaping (URL) -> Void,
        onClose: @escaping () -> Void,
        onOCR: @escaping () -> Void
    ) {
        self.renderer = renderer
        self.onCopy = onCopy
        self.onSave = onSave
        self.onSaveAs = onSaveAs
        self.onClose = onClose
        self.onOCR = onOCR

        let editor = AnnotatorEditor(document: state.document)
        self.editor = editor

        let canvas = AnnotatorCanvasView(document: state.document)
        self.canvas = canvas
        let toolbar = AnnotatorToolbar(frame: .zero)
        self.toolbar = toolbar

        let window = AnnotatorWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Annotate"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .utilityWindow
        window.contentMinSize = NSSize(width: 480, height: 320)

        super.init(window: window)

        window.delegate = self
        window.onKeyEvent = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }

        let content = NSView(frame: .zero)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        wireEditor()
        wireToolbar()
        wireCanvas()
        syncChrome()

        let frame = initialWindowFrame(for: state.document, on: NSScreen.main)
        window.setFrame(frame, display: false)
        window.center()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Public API

    /// Attach the workflow used by `AnnotatorEditor.sync(to:)`. Required before `show()`.
    public func bind(workflow: CaptureWorkflow) {
        self.workflow = workflow
        syncToWorkflow()
    }

    public func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        canvas.zoomToFit()
        window.makeFirstResponder(canvas)
        syncChrome()
    }

    override public func close() {
        isProgrammaticClose = true
        window?.close()
        isProgrammaticClose = false
    }

    /// External reset (effect `.updateAnnotator`). Replaces the editor document and redraws.
    /// Ignores echoes of our own buffer so local undo survives `updateAnnotatorDocument`.
    public func update(state: AnnotatorState) {
        if state.document == editor.document {
            canvas.needsDisplay = true
            syncChrome()
            return
        }
        let replacement = AnnotatorEditor(document: state.document)
        editor = replacement
        wireEditor()
        canvas.setDocument(state.document)
        syncChrome()
    }

    /// Current live document (marks + crop). SHELL may read this before dispatch.
    public var currentDocument: AnnotatorDocument { editor.document }

    /// Flattened preview via the injected renderer (workflow also flattens for output).
    public func flattenedImage() throws -> CapturedImage {
        try renderer.render(editor.document)
    }

    // MARK: - Wiring

    private func syncToWorkflow() {
        guard let workflow else { return }
        editor.sync(to: workflow)
    }

    private func notifyOutput(_ body: () -> Void) {
        canvas.commitTextEditing()
        syncToWorkflow()
        body()
    }

    private func wireEditor() {
        editor.onDidChange = { [weak self] changed in
            guard let self else { return }
            canvas.document = changed.document
            syncChrome()
            syncToWorkflow()
        }
    }

    private func wireToolbar() {
        toolbar.onSelectTool = { [weak self] tool in
            guard let self else { return }
            activeTool = tool
            canvas.activeTool = tool
            syncChrome()
        }
        toolbar.onChangeColor = { [weak self] color in
            guard let self else { return }
            strokeColor = color
            canvas.strokeColor = color
        }
        toolbar.onChangeStrokeWidth = { [weak self] width in
            guard let self else { return }
            strokeWidth = width
            canvas.strokeWidth = width
        }
        toolbar.onUndo = { [weak self] in self?.performUndo() }
        toolbar.onRedo = { [weak self] in self?.performRedo() }
        toolbar.onOCR = { [weak self] in
            guard let self else { return }
            notifyOutput { self.onOCR() }
        }
        toolbar.onCopy = { [weak self] in
            guard let self else { return }
            notifyOutput { self.onCopy() }
        }
        toolbar.onSave = { [weak self] in
            guard let self else { return }
            notifyOutput { self.onSave() }
        }
        toolbar.onSaveAs = { [weak self] in self?.beginSaveAs() }
        toolbar.onApplyCrop = { [weak self] in
            self?.canvas.applyPendingCrop()
            self?.syncChrome()
        }
        toolbar.onCancelCrop = { [weak self] in
            self?.canvas.cancelPendingCrop()
            self?.syncChrome()
        }
    }

    private func wireCanvas() {
        canvas.activeTool = activeTool
        canvas.strokeColor = strokeColor
        canvas.strokeWidth = strokeWidth
        canvas.onApply = { [weak self] transform in
            self?.editor.apply(transform)
        }
        canvas.onCropStateChange = { [weak self] in
            self?.syncChrome()
        }
    }

    private func syncChrome() {
        toolbar.setState(
            selectedTool: activeTool,
            color: strokeColor,
            strokeWidth: strokeWidth,
            canUndo: editor.canUndo,
            canRedo: editor.canRedo,
            cropPending: canvas.pendingCrop != nil
        )
    }

    private func performUndo() {
        canvas.commitTextEditing()
        editor.undo()
    }

    private func performRedo() {
        canvas.commitTextEditing()
        editor.redo()
    }

    /// Controller presents `NSSavePanel`, then reports the URL (story 28).
    private func beginSaveAs() {
        guard let window else { return }
        canvas.commitTextEditing()
        syncToWorkflow()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QuickShot screenshot.png"
        panel.message = "Save flattened PNG"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            notifyOutput { self.onSaveAs(url) }
        }
    }

    // MARK: - Keys

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Let the canvas claim Escape for text cancel first.
        if canvas.handleKeyEvent(event) {
            return true
        }
        if canvas.isEditingText {
            return false
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "z", "Z":
                if event.modifierFlags.contains(.shift) {
                    performRedo()
                } else {
                    performUndo()
                }
                return true
            case "y", "Y":
                performRedo()
                return true
            default:
                break
            }
        }
        return false
    }

    // MARK: - Window sizing + delegate

    private func initialWindowFrame(for document: AnnotatorDocument, on screen: NSScreen?) -> NSRect {
        let screen = screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxContent = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let pixel = document.baseImage.size
        guard pixel.width > 0, pixel.height > 0 else {
            return NSRect(
                x: visible.midX - 320,
                y: visible.midY - 200,
                width: 640,
                height: 400 + AnnotatorToolbar.preferredHeight
            )
        }

        let padding: CGFloat = 24
        let available = CGSize(
            width: max(120, maxContent.width - padding),
            height: max(120, maxContent.height - padding - AnnotatorToolbar.preferredHeight)
        )
        // Fit-to-window when the image is large; otherwise comfortable 1:1 (pixel → point).
        let scale = min(1, available.width / pixel.width, available.height / pixel.height)
        let contentWidth = max(480, pixel.width * scale + padding)
        let contentHeight = max(320, pixel.height * scale + padding + AnnotatorToolbar.preferredHeight)
        return NSRect(
            x: visible.midX - contentWidth / 2,
            y: visible.midY - contentHeight / 2,
            width: contentWidth,
            height: contentHeight
        )
    }

    public func windowWillClose(_ notification: Notification) {
        canvas.commitTextEditing()
        if !isProgrammaticClose {
            onClose()
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        canvas.commitTextEditing()
    }
}
