import AppKit
import ImageIO
import QuickShotCore
import UniformTypeIdentifiers

/// Composition root. Wires menu, shortcuts, thumbnails, selection, annotator, OCR,
/// settings, login item, and permission UI onto one `CaptureWorkflow` (SPEC Implementation Decisions).
@MainActor
final class AppController {
    private let services: (adapters: SystemAdapters, renderer: ImageRenderer)
    private let preferencesStore: PreferencesStore
    private let workflow: CaptureWorkflow
    private let statusItem: StatusItemController
    private let thumbnailCoordinator: ThumbnailCoordinator
    private let selectionCoordinator: SelectionCoordinator
    private let ocrReviewCoordinator: OCRReviewCoordinator
    private let shortcutController: ShortcutController
    private let settingsWindowController: SettingsWindowController
    private let permissionAlert: PermissionAlertController
    private let loginItem: LoginItemController

    private var annotator: AnnotatorWindowController?

    init() {
        let services = LiveServices.make()
        self.services = services

        let store = PreferencesStore()
        self.preferencesStore = store
        let prefs = store.load()

        let workflow = CaptureWorkflow(
            adapters: services.adapters,
            renderer: services.renderer,
            preferences: prefs
        )
        self.workflow = workflow

        self.statusItem = StatusItemController()
        self.thumbnailCoordinator = ThumbnailCoordinator()
        self.selectionCoordinator = SelectionCoordinator()
        self.ocrReviewCoordinator = OCRReviewCoordinator()
        self.shortcutController = ShortcutController(
            shortcuts: services.adapters.shortcuts,
            initial: prefs
        )
        self.settingsWindowController = SettingsWindowController(preferences: prefs)
        self.permissionAlert = PermissionAlertController()
        self.loginItem = LoginItemController()
    }

    func start() {
        wireWorkflow()
        wireStatusItem()
        wireThumbnails()
        wireSelection()
        wireOCRReview()
        wireShortcuts()
        wireSettings()

        statusItem.install()
        statusItem.updateShortcutHints(workflow.state.preferences)

        do {
            try shortcutController.rebind(prefs: workflow.state.preferences)
        } catch {
            presentError(asWorkflowError(error), captureStillAvailable: false)
        }

        loginItem.registerAtLaunch()
        settingsWindowController.setLoginEnabled(loginItem.isEnabled)
    }

    // MARK: - Workflow → UI

    private func wireWorkflow() {
        workflow.onEffect = { [weak self] effect in
            self?.handleEffect(effect)
        }
    }

    private func handleEffect(_ effect: WorkflowEffect) {
        switch effect {
        case let .showThumbnail(item):
            thumbnailCoordinator.show(item, position: workflow.state.preferences.thumbnailPosition)

        case let .hideThumbnail(id):
            thumbnailCoordinator.hide(id: id)

        case .restackThumbnails:
            thumbnailCoordinator.restack(position: workflow.state.preferences.thumbnailPosition)

        case let .beginSelection(session):
            selectionCoordinator.begin(session: session)
            selectionCoordinator.setMode(session.mode)

        case .endSelection:
            selectionCoordinator.end()

        case let .showAnnotator(state):
            presentAnnotator(state)

        case .hideAnnotator:
            // Programmatic close — does not fire onClose / closeAnnotatorWithoutOutput.
            annotator?.close()
            annotator = nil

        case let .updateAnnotator(state):
            annotator?.update(state: state)

        case let .showOCRReview(review):
            let anchor = annotator?.window?.frame
            ocrReviewCoordinator.show(review, relativeTo: anchor)

        case .hideOCRReview:
            ocrReviewCoordinator.hide()

        case let .showError(error, captureStillAvailable):
            presentError(error, captureStillAvailable: captureStillAvailable)

        case .requestCapturePermission:
            requestCapturePermission()

        case let .setDockVisible(visible):
            // Stories 3–4. LSUIElement stays true; policy switches the Dock icon.
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
    }

    private func presentAnnotator(_ state: AnnotatorState) {
        if let existing = annotator {
            existing.close()
            annotator = nil
        }
        // NOTE(planner): ANNO contract. bind() syncs the editor into the workflow
        // before Copy / Save / OCR (notifyOutput also syncs on each of those).
        let controller = AnnotatorWindowController(
            state: state,
            renderer: workflow.renderer,
            onCopy: { [weak self] in
                self?.workflow.dispatch(.annotatorCopied)
            },
            onSave: { [weak self] in
                self?.workflow.dispatch(.annotatorSaved(nil))
            },
            onSaveAs: { [weak self] url in
                self?.workflow.dispatch(.annotatorSaved(url))
            },
            onClose: { [weak self] in
                self?.workflow.dispatch(.closeAnnotatorWithoutOutput)
            },
            onOCR: { [weak self] in
                self?.workflow.dispatch(.ocrAnnotatorImage)
            }
        )
        // Store before bind(): bind syncs and emits updateAnnotator back at us.
        annotator = controller
        controller.bind(workflow: workflow)
        NSApp.setActivationPolicy(.regular)
        controller.show()
    }

    private func requestCapturePermission() {
        permissionAlert.show(
            onContinue: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let granted = await self.workflow.adapters.capture.requestCapturePermission()
                    if !granted {
                        self.workflow.dispatch(.permissionDenied)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.workflow.dispatch(.permissionDenied)
            }
        )
    }

    private func presentError(_ error: WorkflowError, captureStillAvailable: Bool) {
        if case .capturePermissionDenied = error {
            permissionAlert.showPermissionError(error.message)
            return
        }
        permissionAlert.showError(error.message, captureStillAvailable: captureStillAvailable)
    }

    private func asWorkflowError(_ error: Error) -> WorkflowError {
        (error as? WorkflowError) ?? .captureFailed(String(describing: error))
    }

    // MARK: - UI → workflow

    private func wireStatusItem() {
        statusItem.onArea = { [weak self] in
            self?.workflow.dispatch(.startAreaCapture)
        }
        statusItem.onWindow = { [weak self] in
            self?.workflow.dispatch(.startWindowCapture)
        }
        statusItem.onDisplay = { [weak self] in
            self?.workflow.dispatch(.startDisplayCapture)
        }
        statusItem.onOCRImage = { [weak self] in
            self?.presentOCRImagePanel()
        }
        statusItem.onSettings = { [weak self] in
            self?.settingsWindowController.present()
            self?.settingsWindowController.setLoginEnabled(self?.loginItem.isEnabled ?? false)
        }
        statusItem.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func presentOCRImagePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .image]
        panel.message = "Choose an image to recognize text"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.workflow.dispatch(.ocrImage(url))
        }
    }

    private func wireThumbnails() {
        thumbnailCoordinator.onCopy = { [weak self] id in
            self?.workflow.dispatch(.copy(id))
        }
        thumbnailCoordinator.onSave = { [weak self] id in
            self?.workflow.dispatch(.save(id))
        }
        thumbnailCoordinator.onSaveAs = { [weak self] id in
            self?.presentSaveAs(for: id)
        }
        thumbnailCoordinator.onDiscard = { [weak self] id in
            self?.workflow.dispatch(.discard(id))
        }
        thumbnailCoordinator.onOpenAnnotator = { [weak self] id in
            self?.workflow.dispatch(.openAnnotator(id))
        }
        thumbnailCoordinator.onDragCompleted = { [weak self] id in
            self?.workflow.dispatch(.dragCompleted(id))
        }
        thumbnailCoordinator.onDragFailed = { [weak self] id in
            self?.workflow.dispatch(.dragFailed(id))
        }
        thumbnailCoordinator.pngDataForDrag = { [weak self] id in
            guard let self,
                  let image = self.workflow.state.pendingCapture(id: id)?.image
            else { return nil }
            return Self.pngData(from: image)
        }
    }

    private func presentSaveAs(for id: PendingCapture.ID) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        let suggested = workflow.adapters.files.makeDownloadURL(date: workflow.now())
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.message = "Save flattened PNG"
        // The chip lives in a `.nonactivatingPanel` thumbnail, so clicking it never
        // makes QuickShot frontmost. `NSSavePanel.begin` presents app-modally and
        // does not activate, so the sheet is ordered behind whatever app the user was
        // in. Activate first so the dialog is the outermost window.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.workflow.dispatch(.saveAs(id, url))
        }
    }

    private func wireSelection() {
        selectionCoordinator.onAreaSelected = { [weak self] rect in
            self?.workflow.dispatch(.areaSelected(rect))
        }
        selectionCoordinator.onWindowSelected = { [weak self] id in
            self?.workflow.dispatch(.windowSelected(id))
        }
        selectionCoordinator.onCancelled = { [weak self] in
            self?.workflow.dispatch(.selectionCancelled)
        }
        selectionCoordinator.onModeChanged = { [weak self] mode in
            self?.workflow.dispatch(.selectionModeChanged(mode))
        }
        selectionCoordinator.windowLookup = { [weak self] point in
            guard let self else { return nil }
            let capture = self.workflow.adapters.capture
            guard let id = capture.windowID(under: point) else { return nil }
            let frame = capture.windowFrame(for: id) ?? .zero
            return (id: id, frame: frame)
        }
    }

    private func wireOCRReview() {
        ocrReviewCoordinator.onCopy = { [weak self] in
            self?.workflow.dispatch(.ocrReviewCopy)
        }
        ocrReviewCoordinator.onDismiss = { [weak self] in
            self?.workflow.dispatch(.ocrReviewDismiss)
        }
    }

    private func wireShortcuts() {
        shortcutController.onTrigger = { [weak self] id in
            guard let self else { return }
            switch id {
            case ShortcutController.ID.area.rawValue:
                self.workflow.dispatch(.startAreaCapture)
            case ShortcutController.ID.window.rawValue:
                self.workflow.dispatch(.startWindowCapture)
            case ShortcutController.ID.display.rawValue:
                self.workflow.dispatch(.startDisplayCapture)
            case ShortcutController.ID.ocr.rawValue:
                // OCR global binding starts a region selection (stories 7, 44).
                // Menu "OCR Image…" is the file picker entry point.
                self.workflow.dispatch(.startOCRSelection)
            default:
                break
            }
        }
    }

    private func wireSettings() {
        settingsWindowController.onApply = { [weak self] prefs in
            guard let self else { return false }
            do {
                try self.shortcutController.rebind(prefs: prefs)
            } catch {
                self.presentError(self.asWorkflowError(error), captureStillAvailable: false)
                return false
            }
            self.preferencesStore.save(prefs)
            self.workflow.dispatch(.preferencesChanged(prefs))
            self.statusItem.updateShortcutHints(prefs)
            self.thumbnailCoordinator.restack(position: prefs.thumbnailPosition)
            return true
        }
        settingsWindowController.onLoginItemChanged = { [weak self] enabled in
            guard let self else { return }
            do {
                try self.loginItem.setEnabled(enabled)
            } catch {
                self.settingsWindowController.setLoginEnabled(self.loginItem.isEnabled)
            }
        }
    }

    // MARK: - PNG

    private static func pngData(from image: CapturedImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
