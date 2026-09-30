import AppKit
import QuickShotCore
import XCTest
@testable import QuickShot

@MainActor
final class ThumbnailDragPayloadTests: XCTestCase {
    private let fileStore = ThumbnailDragFileStore()

    func testOneThumbnailProducesOnePasteboardItem() throws {
        defer { fileStore.cleanup() }
        let (payload, _) = try makePayload()
        let items = try XCTUnwrap(payload.makeDraggingItems(in: NSRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(items.count, 1, "One thumbnail must not show a two-item drag badge")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(items.map { $0.item as! NSPasteboardWriting }))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        let data = try XCTUnwrap(pasteboard.data(forType: .png))
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.count, 1, "Finder must receive exactly one file URL")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), data)
    }

    func testWezTermReceivesAnExistingPNGPath() throws {
        defer { fileStore.cleanup() }
        let (payload, data) = try makePayload()
        let items = try XCTUnwrap(payload.makeDraggingItems(in: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(items.map { $0.item as! NSPasteboardWriting }))
        // WezTerm registers NSFilenamesPboardType and reads its property list.
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let paths = try XCTUnwrap(pasteboard.propertyList(forType: filenamesType) as? [String])
        XCTAssertEqual(paths.count, 1)
        let url = URL(fileURLWithPath: try XCTUnwrap(paths.first))
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testSuccessfulDropKeepsFileAfterPayloadIsReleasedUntilCleanup() throws {
        defer { fileStore.cleanup() }
        var completed = 0
        var failed = 0
        var payload: ThumbnailDragPayload?
        let data: Data
        (payload, data) = try makePayload(onCompleted: { completed += 1 }, onFailed: { failed += 1 })
        let url = try exportedURL(from: XCTUnwrap(payload))
        let session = NSDraggingSession()
        payload?.draggingSession(session, endedAt: .zero, operation: .copy)
        payload?.draggingSession(session, endedAt: .zero, operation: [])
        payload = nil
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(try Data(contentsOf: url), data)
        fileStore.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelledDropRemovesTemporaryFileAndFailsOnlyOnce() throws {
        defer { fileStore.cleanup() }
        var completed = 0
        var failed = 0
        let (payload, _) = try makePayload(onCompleted: { completed += 1 }, onFailed: { failed += 1 })
        let url = try exportedURL(from: payload)
        let session = NSDraggingSession()
        payload.draggingSession(session, endedAt: .zero, operation: [])
        payload.draggingSession(session, endedAt: .zero, operation: .copy)
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(failed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSeparateExportsDoNotOverwriteEachOther() throws {
        defer { fileStore.cleanup() }
        let id = UUID()
        let first = try fileStore.writePNG(Data([1]), captureID: id)
        let second = try fileStore.writePNG(Data([2]), captureID: id)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    func testMissingPNGProviderFallsBackToEncodingTheImage() throws {
        defer { fileStore.cleanup() }
        let (payload, _) = try makePayload(providePNG: false)
        let url = try exportedURL(from: payload)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        XCTAssertEqual(bitmap.pixelsWide, 2)
        XCTAssertEqual(bitmap.pixelsHigh, 2)
    }

    func testExportFailureReportsFailureWithoutCompletingDrag() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let unavailableStore = ThumbnailDragFileStore(directory: blocker)
        var failed = 0
        let (payload, _) = try makePayload(onCompleted: { XCTFail("Failed export completed") },
                                          onFailed: { failed += 1 }, fileStore: unavailableStore)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        payload.begin(in: view, event: event)
        XCTAssertEqual(failed, 1)
    }

    private func exportedURL(from payload: ThumbnailDragPayload) throws -> URL {
        let items = try XCTUnwrap(payload.makeDraggingItems(in: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let item = try XCTUnwrap(items.first?.item as? NSPasteboardItem)
        return try XCTUnwrap(URL(string: XCTUnwrap(item.string(forType: .fileURL))))
    }

    private func makePayload(onCompleted: @escaping () -> Void = {},
                             onFailed: @escaping () -> Void = {},
                             fileStore: ThumbnailDragFileStore? = nil,
                             providePNG: Bool = true) throws -> (ThumbnailDragPayload, Data) {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = CapturedImage(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image.cgImage).representation(using: .png, properties: [:]))
        return (ThumbnailDragPayload(captureID: UUID(), image: image, pngData: { providePNG ? data : nil },
                                     onCompleted: onCompleted, onFailed: onFailed,
                                     fileStore: fileStore ?? self.fileStore), data)
    }
}
