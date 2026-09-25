import CoreGraphics
import Foundation
import ImageIO
@testable import QuickShotCore

// MARK: - Shared test errors

enum MockError: Error, Equatable {
    case boom
    case denied
}

// MARK: - Capture

final class MockCaptureService: CaptureServicing, @unchecked Sendable {
    var permission = true
    var displayImage: CapturedImage?
    var displayError: Error?
    var windowImage: CapturedImage?
    var windowError: Error?
    var cropError: Error?
    var requestPermissionResult = true

    private(set) var captureDisplayCallCount = 0
    private(set) var lastIncludePointer: Bool?
    private(set) var windowCaptureCalls: [(id: CGWindowID, includeShadow: Bool, includePointer: Bool)] = []
    private(set) var cropCalls: [CGRect] = []
    private(set) var requestPermissionCallCount = 0

    func hasCapturePermission() -> Bool {
        permission
    }

    func requestCapturePermission() async -> Bool {
        requestPermissionCallCount += 1
        return requestPermissionResult
    }

    func captureDisplay(includePointer: Bool) async throws -> CapturedImage {
        captureDisplayCallCount += 1
        lastIncludePointer = includePointer
        if let displayError { throw displayError }
        return displayImage ?? makeTestImage(width: 40, height: 40, color: .black)
    }

    func captureWindow(
        id: CGWindowID,
        includeShadow: Bool,
        includePointer: Bool
    ) async throws -> CapturedImage {
        windowCaptureCalls.append((id, includeShadow, includePointer))
        if let windowError { throw windowError }
        return windowImage ?? makeTestImage(width: 20, height: 16, color: .green)
    }

    /// Real CGImage crop (top-left pixel space) so output sizes and colors assert cleanly.
    /// `rect` is Cocoa global points (origin bottom-left) in the frozen frame's space.
    func cropToCapture(_ frame: CapturedImage, rect: CGRect) throws -> CapturedImage {
        cropCalls.append(rect)
        if let cropError { throw cropError }

        let imageW = frame.pixelWidth
        let imageH = frame.pixelHeight

        let x = Int(rect.origin.x.rounded(.down))
        let w = Int(rect.width.rounded(.down))
        let h = Int(rect.height.rounded(.down))
        // Cocoa bottom-left → CGImage top-left (same flip as ScreenCaptureService).
        let yTop = Int((CGFloat(imageH) - rect.origin.y - rect.height).rounded(.down))

        guard w > 0, h > 0, x >= 0, yTop >= 0, x + w <= imageW, yTop + h <= imageH else {
            throw WorkflowError.captureFailed("crop rect out of bounds")
        }

        guard let out = frame.cgImage.cropping(to: CGRect(x: x, y: yTop, width: w, height: h)) else {
            throw WorkflowError.captureFailed("crop failed")
        }
        return CapturedImage(cgImage: out)
    }

    func windowID(under globalPoint: CGPoint) -> CGWindowID? {
        nil
    }

    func windowFrame(for id: CGWindowID) -> CGRect? {
        nil
    }
}

// MARK: - OCR

final class MockOCRService: OCRServicing, @unchecked Sendable {
    var result = OCRResult(text: "hello\nworld", lines: ["hello", "world"])
    var error: Error?
    private(set) var calls: [(image: CapturedImage, region: CGRect?)] = []

    func recognize(in image: CapturedImage, region: CGRect?) async throws -> OCRResult {
        calls.append((image, region))
        if let error { throw error }
        return result
    }
}

// MARK: - Clipboard

final class MockClipboardService: ClipboardServicing, @unchecked Sendable {
    var imageError: Error?
    var textError: Error?
    private(set) var images: [CapturedImage] = []
    private(set) var texts: [String] = []

    func copyImage(_ image: CapturedImage) throws {
        if let imageError { throw imageError }
        images.append(image)
    }

    func copyText(_ text: String) throws {
        if let textError { throw textError }
        texts.append(text)
    }
}

// MARK: - Files

final class MockFileService: FileServicing, @unchecked Sendable {
    var writeError: Error?
    /// Names reserved or written; mirrors production exists-check collision safety.
    private var takenNames = Set<String>()
    private(set) var writtenURLs: [URL] = []

    func downloadsDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
    }

    func makeDownloadURL(date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let stem = "QuickShot \(formatter.string(from: date))"
        var name = stem
        var counter = 2
        while takenNames.contains("\(name).png") {
            name = "\(stem) (\(counter))"
            counter += 1
        }
        takenNames.insert("\(name).png")
        return downloadsDirectory().appendingPathComponent("\(name).png")
    }

    func writePNG(_ image: CapturedImage, to url: URL) throws {
        if let writeError { throw writeError }
        writtenURLs.append(url)
        takenNames.insert(url.lastPathComponent)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw WorkflowError.saveFailed("could not create image destination")
        }
        CGImageDestinationAddImage(dest, image.cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WorkflowError.saveFailed("could not finalize PNG")
        }
    }
}

// MARK: - Shortcuts

final class MockShortcutService: ShortcutServicing, @unchecked Sendable {
    var registerError: Error?
    private(set) var registered: [(id: String, binding: KeyBinding)] = []
    private(set) var unregisteredIDs: [String] = []
    private(set) var unregisterAllCallCount = 0

    func register(
        id: String,
        binding: KeyBinding,
        handler: @escaping @Sendable () -> Void
    ) throws {
        if let registerError { throw registerError }
        registered.append((id, binding))
    }

    func unregister(id: String) {
        unregisteredIDs.append(id)
    }

    func unregisterAll() {
        unregisterAllCallCount += 1
    }
}

// MARK: - Renderer

final class MockImageRenderer: ImageRendering, @unchecked Sendable {
    var error: Error?
    /// When set, returned instead of the derived image.
    var resultImage: CapturedImage?
    private(set) var recordedDocuments: [AnnotatorDocument] = []

    func render(_ document: AnnotatorDocument) throws -> CapturedImage {
        recordedDocuments.append(document)
        if let error { throw error }
        if let resultImage { return resultImage }
        let size = document.crop?.size ?? document.baseImage.size
        return makeTestImage(width: Int(size.width), height: Int(size.height), color: .purple)
    }
}
