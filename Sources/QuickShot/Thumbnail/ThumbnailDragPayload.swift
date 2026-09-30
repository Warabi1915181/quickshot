import AppKit
import QuickShotCore
import UniformTypeIdentifiers

/// One file URL + PNG pasteboard item for thumbnail drags (story 30).
/// Success → onCompleted (story 31). Failed drop after a real drag → onFailed (story 55).
final class ThumbnailDragPayload: NSObject, NSDraggingSource {
    private let captureID: PendingCapture.ID
    private let image: CapturedImage
    private let pngData: () -> Data?
    private let onCompleted: () -> Void
    private let onFailed: () -> Void
    private let fileStore: ThumbnailDragFileStore

    private var fileURL: URL?
    private var finished = false

    init(
        captureID: PendingCapture.ID,
        image: CapturedImage,
        pngData: @escaping () -> Data?,
        onCompleted: @escaping () -> Void,
        onFailed: @escaping () -> Void,
        fileStore: ThumbnailDragFileStore = .shared
    ) {
        self.captureID = captureID
        self.image = image
        self.pngData = pngData
        self.onCompleted = onCompleted
        self.onFailed = onFailed
        self.fileStore = fileStore
        super.init()
    }

    func begin(in view: NSView, event: NSEvent) {
        guard let window = view.window, let items = makeDraggingItems(in: view.bounds) else {
            finish(success: false)
            return
        }
        window.beginDraggingSession(items: items, event: event, source: self)
    }

    func makeDraggingItems(in bounds: NSRect) -> [NSDraggingItem]? {
        guard let data = resolvePNG() else {
            return nil
        }
        let url: URL
        do {
            url = try fileStore.writePNG(data, captureID: captureID)
        } catch {
            return nil
        }
        if let fileURL { fileStore.removeFile(at: fileURL) }
        fileURL = url

        // These are alternate representations of ONE capture, not separate items.
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .png)
        // AppKit also exposes file URLs as the legacy NSFilenamesPboardType
        // filename list that WezTerm reads. Legacy types cannot be set on items.
        pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: NSImage(cgImage: image.cgImage, size: bounds.size))
        return [item]
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
            if let fileURL { fileStore.removeFile(at: fileURL) }
            fileURL = nil
            onFailed()
        }
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
