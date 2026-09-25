import CoreGraphics
import Foundation
import ImageIO

// MARK: - Workflow types
// Frozen shapes. Dispatch logic is filled by the CORE agent.

public enum WorkflowEvent: Sendable, Equatable {
    // Capture entry points (menu + global shortcuts + selection keys)
    case startAreaCapture
    case startWindowCapture
    case startDisplayCapture
    case startOCRSelection
    case ocrImage(URL)
    case ocrAnnotatorImage

    // Selection session
    case selectionModeChanged(SelectionMode)
    case selectionCancelled
    case areaSelected(CGRect)
    case windowSelected(CGWindowID)

    // Pending item actions (thumbnails)
    case copy(PendingCapture.ID)
    case save(PendingCapture.ID)
    case saveAs(PendingCapture.ID, URL)
    case discard(PendingCapture.ID)
    case openAnnotator(PendingCapture.ID)
    case dragCompleted(PendingCapture.ID)
    case dragFailed(PendingCapture.ID)

    // Annotator — workflow flattens `AnnotatorState.document` via `ImageRendering`.
    case closeAnnotatorWithoutOutput
    case annotatorCopied
    /// `nil` URL = Downloads collision-safe name.
    case annotatorSaved(URL?)

    // OCR review (Return / Escape — story 50)
    case ocrReviewCopy
    case ocrReviewDismiss

    // Permission
    case permissionDenied

    // Preferences changed from Settings (shortcut rebind happens in shell)
    case preferencesChanged(AppPreferences)
}

public struct OCRReviewState: Sendable, Equatable {
    public var id: UUID
    public var result: OCRResult
    /// Pending capture that produced this review, when entered via thumbnail path.
    /// `nil` for menu "OCR Image…" of a file that was never a pending capture.
    public var sourceCaptureID: PendingCapture.ID?
    /// True when the annotator is still open behind the review.
    public var fromAnnotator: Bool

    public init(
        id: UUID = UUID(),
        result: OCRResult,
        sourceCaptureID: PendingCapture.ID? = nil,
        fromAnnotator: Bool = false
    ) {
        self.id = id
        self.result = result
        self.sourceCaptureID = sourceCaptureID
        self.fromAnnotator = fromAnnotator
    }
}

public struct AnnotatorState: Sendable, Equatable {
    public var captureID: PendingCapture.ID
    public var document: AnnotatorDocument
    public var undoStack: [DocumentSnapshot]
    public var redoStack: [DocumentSnapshot]

    public init(
        captureID: PendingCapture.ID,
        document: AnnotatorDocument,
        undoStack: [DocumentSnapshot] = [],
        redoStack: [DocumentSnapshot] = []
    ) {
        self.captureID = captureID
        self.document = document
        self.undoStack = undoStack
        self.redoStack = redoStack
    }
}

public struct WorkflowState: Sendable, Equatable {
    public var preferences: AppPreferences
    /// Pending captures, newest last. Each owns one thumbnail (story 19/24).
    public var pending: [PendingCapture]
    /// Active screen selection, if any. Screen is frozen for `frozenFrame`.
    public var selection: SelectionSession?
    public var annotator: AnnotatorState?
    public var ocrReview: OCRReviewState?
    /// Set when the user still needs Screen Recording permission.
    public var needsCapturePermission: Bool

    public init(
        preferences: AppPreferences = AppPreferences(),
        pending: [PendingCapture] = [],
        selection: SelectionSession? = nil,
        annotator: AnnotatorState? = nil,
        ocrReview: OCRReviewState? = nil,
        needsCapturePermission: Bool = false
    ) {
        self.preferences = preferences
        self.pending = pending
        self.selection = selection
        self.annotator = annotator
        self.ocrReview = ocrReview
        self.needsCapturePermission = needsCapturePermission
    }

    public func pendingCapture(id: PendingCapture.ID) -> PendingCapture? {
        pending.first { $0.id == id }
    }
}

public enum WorkflowEffect: Sendable, Equatable {
    case showThumbnail(PendingCapture)
    case hideThumbnail(PendingCapture.ID)
    case restackThumbnails
    case beginSelection(SelectionSession)
    case endSelection
    case showAnnotator(AnnotatorState)
    case hideAnnotator
    /// Re-render annotator after document / undo / redo change.
    case updateAnnotator(AnnotatorState)
    case showOCRReview(OCRReviewState)
    case hideOCRReview
    case showError(WorkflowError, captureStillAvailable: Bool)
    case requestCapturePermission
    case setDockVisible(Bool)
}

// MARK: - Workflow

/// Single application-level capture workflow (SPEC Implementation Decisions).
/// Menu actions, global shortcuts, thumbnail controls, and annotator commands
/// all enter here. System I/O goes through `SystemAdapters`.
@MainActor
public final class CaptureWorkflow {
    public private(set) var state: WorkflowState {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public var onStateChange: ((WorkflowState) -> Void)?
    public var onEffect: ((WorkflowEffect) -> Void)?

    public let adapters: SystemAdapters
    public let renderer: any ImageRendering

    /// Test/injection point: clock for filename timestamps.
    public var now: () -> Date = { Date() }

    /// Serializes async event work (capture / OCR) so rapid commands stay ordered.
    private var pipeline: Task<Void, Never>?
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    public init(
        adapters: SystemAdapters,
        renderer: any ImageRendering,
        preferences: AppPreferences = AppPreferences()
    ) {
        self.adapters = adapters
        self.renderer = renderer
        self.state = WorkflowState(preferences: preferences)
    }

    public func dispatch(_ event: WorkflowEvent) {
        switch event {
        case .startAreaCapture:
            startSelectionCapture(.area)
        case .startWindowCapture:
            startSelectionCapture(.window)
        case .startOCRSelection:
            startSelectionCapture(.ocrRegion)
        case .startDisplayCapture:
            startDisplayCapture()
        case let .ocrImage(url):
            runAsync { await self.performOCRImage(url) }
        case .ocrAnnotatorImage:
            runAsync { await self.performOCRAnnotatorImage() }

        case let .selectionModeChanged(mode):
            selectionModeChanged(mode)
        case .selectionCancelled:
            cancelSelection()
        case let .areaSelected(rect):
            areaSelected(rect)
        case let .windowSelected(id):
            runAsync { await self.performWindowSelected(id) }

        case let .copy(id):
            copyPending(id)
        case let .save(id):
            savePending(id, to: nil)
        case let .saveAs(id, url):
            savePending(id, to: url)
        case let .discard(id):
            discardPending(id)
        case let .openAnnotator(id):
            openAnnotator(id)
        case let .dragCompleted(id):
            removePending(id: id)
        case let .dragFailed(id):
            dragFailed(id)

        case .closeAnnotatorWithoutOutput:
            closeAnnotatorWithoutOutput()
        case .annotatorCopied:
            annotatorCopied()
        case let .annotatorSaved(url):
            annotatorSaved(url)

        case .ocrReviewCopy:
            ocrReviewCopy()
        case .ocrReviewDismiss:
            ocrReviewDismiss()

        case .permissionDenied:
            state.needsCapturePermission = true
            emit(.showError(.capturePermissionDenied, captureStillAvailable: false))

        case let .preferencesChanged(prefs):
            // Shortcut rebind is the shell's job; core only stores values.
            state.preferences = prefs
        }
    }

    /// Sync the in-memory annotator buffer after UI-side edits (`AnnotatorEditor`).
    /// Emits `updateAnnotator` so the canvas can refresh. No-op when closed.
    public func updateAnnotatorDocument(
        _ document: AnnotatorDocument,
        undoStack: [DocumentSnapshot] = [],
        redoStack: [DocumentSnapshot] = []
    ) {
        guard var annotator = state.annotator else { return }
        annotator.document = document
        annotator.undoStack = undoStack
        annotator.redoStack = redoStack
        state.annotator = annotator
        emit(.updateAnnotator(annotator))
    }

    /// Test seam: await async event handlers started by `dispatch`.
    internal func waitForInFlightWork() async {
        while !inFlight.isEmpty {
            let tasks = Array(inFlight.values)
            for task in tasks {
                await task.value
            }
        }
    }

    // MARK: - Async plumbing

    private func runAsync(_ body: @escaping @MainActor () async -> Void) {
        let previous = pipeline
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await body()
            self?.inFlight[id] = nil
        }
        inFlight[id] = task
        pipeline = task
    }

    private func emit(_ effect: WorkflowEffect) {
        onEffect?(effect)
    }

    private func detail(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func asCaptureError(_ error: Error) -> WorkflowError {
        if let workflowError = error as? WorkflowError { return workflowError }
        return .captureFailed(detail(error))
    }

    private func asOCRError(_ error: Error) -> WorkflowError {
        if let workflowError = error as? WorkflowError { return workflowError }
        return .ocrFailed(detail(error))
    }

    private func asCopyError(_ error: Error) -> WorkflowError {
        if let workflowError = error as? WorkflowError { return workflowError }
        return .copyFailed(detail(error))
    }

    private func asSaveError(_ error: Error) -> WorkflowError {
        if let workflowError = error as? WorkflowError { return workflowError }
        return .saveFailed(detail(error))
    }

    private func denyCapturePermission() {
        state.needsCapturePermission = true
        emit(.requestCapturePermission)
    }

    private func appendPending(_ image: CapturedImage, kind: CaptureKind) -> PendingCapture {
        let item = PendingCapture(image: image, kind: kind)
        state.pending.append(item)
        emit(.showThumbnail(item))
        return item
    }

    private func removePending(id: PendingCapture.ID) {
        guard state.pendingCapture(id: id) != nil else { return }
        state.pending.removeAll { $0.id == id }
        emit(.hideThumbnail(id))
    }

    private func clearSelection() {
        guard state.selection != nil else { return }
        state.selection = nil
        emit(.endSelection)
    }

    private func closeAnnotatorUI() {
        guard state.annotator != nil else { return }
        state.annotator = nil
        emit(.hideAnnotator)
        emit(.setDockVisible(false))
    }

    // MARK: - Capture entry points

    private func startSelectionCapture(_ mode: SelectionMode) {
        guard adapters.capture.hasCapturePermission() else {
            denyCapturePermission()
            return
        }
        state.needsCapturePermission = false
        runAsync { await self.beginFrozenSelection(mode) }
    }

    private func beginFrozenSelection(_ mode: SelectionMode) async {
        do {
            let image = try await adapters.capture.captureDisplay(
                includePointer: state.preferences.includePointer
            )
            if state.selection != nil {
                clearSelection()
            }
            // displayBounds is informational for the UI overlay placement.
            // Core is AppKit-free and has no screen geometry adapter, so use the
            // frozen frame's point size at the origin; UI places the overlay itself.
            let session = SelectionSession(
                mode: mode,
                frozenFrame: image,
                displayBounds: CGRect(origin: .zero, size: image.size)
            )
            state.selection = session
            emit(.beginSelection(session))
        } catch {
            emit(.showError(asCaptureError(error), captureStillAvailable: false))
        }
    }

    private func startDisplayCapture() {
        guard adapters.capture.hasCapturePermission() else {
            denyCapturePermission()
            return
        }
        state.needsCapturePermission = false
        runAsync { await self.performDisplayCapture() }
    }

    private func performDisplayCapture() async {
        do {
            let image = try await adapters.capture.captureDisplay(
                includePointer: state.preferences.includePointer
            )
            _ = appendPending(image, kind: .display)
        } catch {
            emit(.showError(asCaptureError(error), captureStillAvailable: false))
        }
    }

    // MARK: - Selection session

    private func selectionModeChanged(_ mode: SelectionMode) {
        guard var selection = state.selection else { return }
        // W / O during selection (stories 12, 44). Same frozen frame, no re-capture.
        selection.mode = mode
        state.selection = selection
    }

    private func cancelSelection() {
        // Story 11: cancel creates no pending item.
        guard state.selection != nil else { return }
        state.selection = nil
        emit(.endSelection)
    }

    private func areaSelected(_ rect: CGRect) {
        guard let selection = state.selection else { return }

        // Window mode completes via `windowSelected`, not a drag rect.
        if selection.mode == .window {
            clearSelection()
            return
        }

        let cropped: CapturedImage
        do {
            cropped = try adapters.capture.cropToCapture(selection.frozenFrame, rect: rect)
        } catch {
            emit(.showError(asCaptureError(error), captureStillAvailable: false))
            clearSelection()
            return
        }

        switch selection.mode {
        case .area:
            _ = appendPending(cropped, kind: .area)
            clearSelection()

        case .ocrRegion:
            // Story 44: OCR region produces review text, not a thumbnail.
            runAsync { await self.performRegionOCR(cropped) }

        case .window:
            clearSelection()
        }
    }

    private func performRegionOCR(_ image: CapturedImage) async {
        do {
            let result = try await adapters.ocr.recognize(in: image, region: nil)
            let review = OCRReviewState(
                result: result,
                sourceCaptureID: nil,
                fromAnnotator: false
            )
            state.ocrReview = review
            emit(.showOCRReview(review))
            clearSelection()
        } catch {
            emit(.showError(asOCRError(error), captureStillAvailable: false))
            clearSelection()
        }
    }

    private func performWindowSelected(_ id: CGWindowID) async {
        do {
            let image = try await adapters.capture.captureWindow(
                id: id,
                includeShadow: state.preferences.includeWindowShadows,
                includePointer: state.preferences.includePointer
            )
            _ = appendPending(image, kind: .window)
            clearSelection()
        } catch {
            emit(.showError(asCaptureError(error), captureStillAvailable: false))
            clearSelection()
        }
    }

    // MARK: - Pending item actions

    private func copyPending(_ id: PendingCapture.ID) {
        guard let item = state.pendingCapture(id: id) else {
            emit(.showError(.noActiveCapture, captureStillAvailable: false))
            return
        }
        do {
            try adapters.clipboard.copyImage(item.image)
            removePending(id: id)
        } catch {
            // Story 55: failed copy keeps the capture.
            emit(.showError(asCopyError(error), captureStillAvailable: true))
        }
    }

    private func savePending(_ id: PendingCapture.ID, to explicitURL: URL?) {
        guard let item = state.pendingCapture(id: id) else {
            emit(.showError(.noActiveCapture, captureStillAvailable: false))
            return
        }
        let url = explicitURL ?? adapters.files.makeDownloadURL(date: now())
        do {
            try adapters.files.writePNG(item.image, to: url)
            removePending(id: id)
        } catch {
            emit(.showError(asSaveError(error), captureStillAvailable: true))
        }
    }

    private func discardPending(_ id: PendingCapture.ID) {
        // Missing id is a no-op (nothing to lose).
        removePending(id: id)
    }

    private func openAnnotator(_ id: PendingCapture.ID) {
        guard let item = state.pendingCapture(id: id) else {
            emit(.showError(.noActiveCapture, captureStillAvailable: false))
            return
        }
        let document = AnnotatorDocument(baseImage: item.image)
        let annotator = AnnotatorState(captureID: id, document: document)
        // Pending item (and its thumbnail) stays so close can return to it (story 34).
        state.annotator = annotator
        emit(.showAnnotator(annotator))
        emit(.setDockVisible(true))
    }

    private func dragFailed(_ id: PendingCapture.ID) {
        // Story 55: keep item; report drag failure.
        guard state.pendingCapture(id: id) != nil else { return }
        emit(.showError(.dragFailed, captureStillAvailable: true))
    }

    // MARK: - Annotator

    private func closeAnnotatorWithoutOutput() {
        // Story 34: pending capture returns to its thumbnail (never left).
        closeAnnotatorUI()
    }

    private func annotatorCopied() {
        guard let annotator = state.annotator else { return }
        let flattened: CapturedImage
        do {
            flattened = try renderer.render(annotator.document)
        } catch {
            emit(.showError(asCaptureError(error), captureStillAvailable: true))
            return
        }
        do {
            try adapters.clipboard.copyImage(flattened)
        } catch {
            emit(.showError(asCopyError(error), captureStillAvailable: true))
            return
        }
        removePending(id: annotator.captureID)
        closeAnnotatorUI()
    }

    private func annotatorSaved(_ explicitURL: URL?) {
        guard let annotator = state.annotator else { return }
        let flattened: CapturedImage
        do {
            flattened = try renderer.render(annotator.document)
        } catch {
            emit(.showError(asCaptureError(error), captureStillAvailable: true))
            return
        }
        let url = explicitURL ?? adapters.files.makeDownloadURL(date: now())
        do {
            try adapters.files.writePNG(flattened, to: url)
        } catch {
            emit(.showError(asSaveError(error), captureStillAvailable: true))
            return
        }
        removePending(id: annotator.captureID)
        closeAnnotatorUI()
    }

    // MARK: - OCR

    private func performOCRImage(_ url: URL) async {
        let image: CapturedImage
        do {
            image = try Self.loadImage(at: url)
        } catch {
            emit(.showError(asOCRError(error), captureStillAvailable: false))
            return
        }
        do {
            let result = try await adapters.ocr.recognize(in: image, region: nil)
            let review = OCRReviewState(
                result: result,
                sourceCaptureID: nil,
                fromAnnotator: false
            )
            state.ocrReview = review
            emit(.showOCRReview(review))
        } catch {
            emit(.showError(asOCRError(error), captureStillAvailable: false))
        }
    }

    private func performOCRAnnotatorImage() async {
        guard let annotator = state.annotator else { return }
        let flattened: CapturedImage
        do {
            flattened = try renderer.render(annotator.document)
        } catch {
            emit(.showError(.ocrFailed(detail(error)), captureStillAvailable: true))
            return
        }
        do {
            let result = try await adapters.ocr.recognize(in: flattened, region: nil)
            let review = OCRReviewState(
                result: result,
                sourceCaptureID: annotator.captureID,
                fromAnnotator: true
            )
            // Story 46: annotator stays open behind the review.
            state.ocrReview = review
            emit(.showOCRReview(review))
        } catch {
            emit(.showError(asOCRError(error), captureStillAvailable: true))
        }
    }

    private func ocrReviewCopy() {
        guard let review = state.ocrReview else { return }
        do {
            try adapters.clipboard.copyText(review.result.text)
            state.ocrReview = nil
            emit(.hideOCRReview)
        } catch {
            let available =
                state.ocrReview?.sourceCaptureID != nil
                || state.annotator != nil
            emit(.showError(asCopyError(error), captureStillAvailable: available))
        }
    }

    private func ocrReviewDismiss() {
        // Story 50 Escape: close without copying.
        guard state.ocrReview != nil else { return }
        state.ocrReview = nil
        emit(.hideOCRReview)
    }

    // MARK: - Image load (ImageIO only — core stays AppKit-free)

    private static func loadImage(at url: URL) throws -> CapturedImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw WorkflowError.ocrFailed("Could not load image at \(url.lastPathComponent).")
        }
        return CapturedImage(cgImage: cgImage)
    }
}

// MARK: - Annotator editor (UI mutation buffer)

/// In-memory annotation edit buffer with undo/redo.
/// The annotator UI owns mutation through this type and reports Copy/Save/Close
/// to `CaptureWorkflow`. Call `CaptureWorkflow.updateAnnotatorDocument` (or
/// `sync(to:)`) after edits so flatten paths see the current document.
@MainActor
public final class AnnotatorEditor {
    public private(set) var document: AnnotatorDocument
    public private(set) var undoStack: [DocumentSnapshot]
    public private(set) var redoStack: [DocumentSnapshot]

    /// Notified after apply / undo / redo.
    public var onDidChange: ((AnnotatorEditor) -> Void)?

    public init(document: AnnotatorDocument) {
        self.document = document
        self.undoStack = []
        self.redoStack = []
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func apply(_ transform: (inout AnnotatorDocument) -> Void) {
        undoStack.append(snapshot())
        redoStack.removeAll()
        transform(&document)
        notify()
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        document.marks = previous.marks
        document.crop = previous.crop
        notify()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        document.marks = next.marks
        document.crop = next.crop
        notify()
    }

    /// Push current document into the workflow annotator buffer.
    public func sync(to workflow: CaptureWorkflow) {
        workflow.updateAnnotatorDocument(document, undoStack: undoStack, redoStack: redoStack)
    }

    private func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(marks: document.marks, crop: document.crop)
    }

    private func notify() {
        onDidChange?(self)
    }
}

// MARK: - Equatable support
// CapturedImage compares by CGImage identity (same rule as `PendingCapture.==`).

extension CapturedImage: Equatable {
    public static func == (lhs: CapturedImage, rhs: CapturedImage) -> Bool {
        lhs.cgImage === rhs.cgImage
    }
}

/// Flattens an `AnnotatorDocument` (marks + crop) into a bitmap.
/// Live: `ImageRenderer`. Tests: `SnapshotImageRenderer` or live renderer on tiny bitmaps.
public protocol ImageRendering: Sendable {
    func render(_ document: AnnotatorDocument) throws -> CapturedImage
}
