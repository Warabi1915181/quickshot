import Foundation
import QuickShotCore

/// Temporary exports, not capture history. Successful drops keep their paths
/// alive until app termination because terminal consumers may read them later.
final class ThumbnailDragFileStore {
    static let shared = ThumbnailDragFileStore()

    private let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuickShot-Drags-\(UUID().uuidString)", isDirectory: true)) {
        self.directory = directory
    }

    func writePNG(_ data: Data, captureID: PendingCapture.ID) throws -> URL {
        let exportDirectory = directory.appendingPathComponent("\(captureID)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = exportDirectory.appendingPathComponent("QuickShot Capture.png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }
    }

    func removeFile(at url: URL) {
        let exportDirectory = url.deletingLastPathComponent()
        guard exportDirectory.deletingLastPathComponent() == directory else { return }
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
