import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Live `ClipboardServicing` via `NSPasteboard.general`.
final class PasteboardService: ClipboardServicing, @unchecked Sendable {

    func copyImage(_ image: CapturedImage) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let size = NSSize(width: image.pixelWidth, height: image.pixelHeight)
        let nsImage = NSImage(cgImage: image.cgImage, size: size)
        let wrote = pasteboard.writeObjects([nsImage])
        // Also publish PNG for clipboard history managers (story 26).
        if let pngData = pngData(from: image.cgImage) {
            pasteboard.setData(pngData, forType: .png)
        }
        if !wrote && pasteboard.data(forType: .png) == nil {
            throw WorkflowError.copyFailed("pasteboard rejected image")
        }
    }

    func copyText(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        if !wrote {
            throw WorkflowError.copyFailed("pasteboard rejected text")
        }
    }

    private func pngData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
