import AppKit
import QuickShotCore
import UniformTypeIdentifiers

/// NSFilePromiseProvider + PNG pasteboard payload for thumbnail drags (story 30).
/// Success → onCompleted (story 31). Failed drop after a real drag → onFailed (story 55).
final class ThumbnailDragPayload: NSObject, NSFilePromiseProviderDelegate, NSDraggingSource {
    private let captureID: PendingCapture.ID
    private let image: CapturedImage
    private let pngData: () -> Data?
    private let onCompleted: () -> Void
    private let onFailed: () -> Void

    private var cachedPNG: Data?
    private var finished = false

    init(
        captureID: PendingCapture.ID,
        image: CapturedImage,
        pngData: @escaping () -> Data?,
        onCompleted: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        self.captureID = captureID
        self.image = image
        self.pngData = pngData
        self.onCompleted = onCompleted
        self.onFailed = onFailed
        super.init()
    }

    func begin(in view: NSView, event: NSEvent) {
        cachedPNG = resolvePNG()
        guard cachedPNG != nil else {
            finish(success: false)
            return
        }

        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        provider.userInfo = captureID

        let dragImage = NSImage(cgImage: image.cgImage, size: view.bounds.size)
        let promiseItem = NSDraggingItem(pasteboardWriter: provider)
        promiseItem.setDraggingFrame(view.bounds, contents: dragImage)

        var items = [promiseItem]
        if let data = cachedPNG {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(data, forType: .png)
            let dataItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            dataItem.setDraggingFrame(view.bounds, contents: dragImage)
            items.append(dataItem)
        }

        guard let window = view.window else {
            finish(success: false)
            return
        }
        window.beginDraggingSession(items: items, event: event, source: self)
    }

    private func resolvePNG() -> Data? {
        pngData() ?? Self.encodePNG(image.cgImage)
    }

    private static func encodePNG(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if success {
            onCompleted()
        } else {
            onFailed()
        }
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        "QuickShot Capture.png"
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let data = cachedPNG ?? resolvePNG() else {
            completionHandler(WorkflowError.dragFailed)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        didFailWithError error: Error
    ) {
        finish(success: false)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finish(success: !operation.isEmpty)
    }
}
