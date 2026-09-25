import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Live `FileServicing`. Collision-safe PNG names under Downloads (story 29).
final class FileService: FileServicing, @unchecked Sendable {

    func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    /// `QuickShot yyyy-MM-dd 'at' HH.mm.ss.SSS.png`, then ` (2)`, ` (3)`… before `.png`.
    /// Locale `en_US_POSIX` for stable digits; timezone is the user's current.
    func makeDownloadURL(date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let stamp = formatter.string(from: date)

        let directory = downloadsDirectory()
        let baseName = "QuickShot \(stamp)"
        var candidate = directory.appendingPathComponent("\(baseName).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(suffix)).png")
            suffix += 1
        }
        return candidate
    }

    func writePNG(_ image: CapturedImage, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw WorkflowError.saveFailed(String(describing: error))
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WorkflowError.saveFailed("could not create PNG destination")
        }
        CGImageDestinationAddImage(dest, image.cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WorkflowError.saveFailed("could not encode PNG")
        }
        do {
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            throw WorkflowError.saveFailed(String(describing: error))
        }
    }
}
