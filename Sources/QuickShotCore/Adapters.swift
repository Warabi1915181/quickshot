import CoreGraphics
import Foundation

// MARK: - System adapters (test seam)
// Live implementations live in Sources/QuickShotCore/Adapters/.
// Tests substitute mocks. UI must not bypass these for system I/O.

public protocol CaptureServicing: Sendable {
    /// True when macOS grants Screen Recording (or equivalent) access.
    func hasCapturePermission() -> Bool

    /// Prompt for Screen Recording access. Returns the post-prompt grant.
    /// May show system UI. Call only after `hasCapturePermission()` is false.
    func requestCapturePermission() async -> Bool

    /// Full-display frame. `includePointer` obeys preferences (story 17/18).
    func captureDisplay(includePointer: Bool) async throws -> CapturedImage

    /// Window frame including shadow when `includeShadow` (story 15/16).
    func captureWindow(
        id: CGWindowID,
        includeShadow: Bool,
        includePointer: Bool
    ) async throws -> CapturedImage

    /// Crop `rect` (Cocoa global points, origin bottom-left) out of `frame`.
    /// Pure helper; does not touch the screen. Used after freeze for area + OCR region.
    func cropToCapture(_ frame: CapturedImage, rect: CGRect) throws -> CapturedImage

    /// Window id under `globalPoint` (Cocoa global points). `nil` if none.
    func windowID(under globalPoint: CGPoint) -> CGWindowID?

    /// Window frame in Cocoa global points for outlining during window selection (story 13).
    func windowFrame(for id: CGWindowID) -> CGRect?
}

public protocol OCRServicing: Sendable {
    /// Recognize text in `image`, optionally limited to `region` (pixel coords, origin top-left).
    /// Any language the system recognizer supports (story 48). Preserve line breaks (story 49).
    func recognize(in image: CapturedImage, region: CGRect?) async throws -> OCRResult
}

public protocol ClipboardServicing: Sendable {
    func copyImage(_ image: CapturedImage) throws
    func copyText(_ text: String) throws
}

public protocol FileServicing: Sendable {
    /// Downloads directory URL.
    func downloadsDirectory() -> URL

    /// Collision-safe timestamped PNG URL under Downloads
    /// (story 29). Name shape: `QuickShot YYYY-MM-dd at HH.mm.ss.SSS.png`,
    /// then ` (2)`, ` (3)`… when the file already exists.
    func makeDownloadURL(date: Date) -> URL

    /// Flatten and write PNG. Creates intermediate directories if needed.
    /// Atomic replace. Throws `WorkflowError.saveFailed` on I/O problems.
    func writePNG(_ image: CapturedImage, to url: URL) throws
}

public protocol ShortcutServicing: Sendable {
    /// Register a global hotkey. `handler` is called on an arbitrary queue;
    /// the app shell will hop to main. Throws `WorkflowError.shortcutConflict`
    /// when the binding cannot be taken (story 7).
    func register(
        id: String,
        binding: KeyBinding,
        handler: @escaping @Sendable () -> Void
    ) throws

    func unregister(id: String)
    func unregisterAll()
}

/// Bundle handed to `CaptureWorkflow`.
public struct SystemAdapters: @unchecked Sendable {
    public var capture: CaptureServicing
    public var ocr: OCRServicing
    public var clipboard: ClipboardServicing
    public var files: FileServicing
    public var shortcuts: ShortcutServicing

    public init(
        capture: CaptureServicing,
        ocr: OCRServicing,
        clipboard: ClipboardServicing,
        files: FileServicing,
        shortcuts: ShortcutServicing
    ) {
        self.capture = capture
        self.ocr = ocr
        self.clipboard = clipboard
        self.files = files
        self.shortcuts = shortcuts
    }
}
