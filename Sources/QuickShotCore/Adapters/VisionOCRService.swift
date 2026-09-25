import CoreGraphics
import Foundation
import Vision

/// Live `OCRServicing` via Vision. Any language the system recognizer supports (story 48).
final class VisionOCRService: OCRServicing, @unchecked Sendable {

    /// `region` is pixel coords, origin top-left on the full image.
    /// Vision `regionOfInterest` is normalized 0...1, origin bottom-left.
    func recognize(in image: CapturedImage, region: CGRect?) async throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // recognitionLanguages intentionally unset (story 48).
        // minimumTextHeight left at default.

        if let region {
            let imgW = CGFloat(image.pixelWidth)
            let imgH = CGFloat(image.pixelHeight)
            guard imgW > 0, imgH > 0, region.width > 0, region.height > 0 else {
                throw WorkflowError.ocrFailed("empty region")
            }
            let x = region.origin.x / imgW
            let width = region.width / imgW
            let y = (imgH - region.origin.y - region.height) / imgH
            let height = region.height / imgH
            request.regionOfInterest = CGRect(x: x, y: y, width: width, height: height)
        }

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw WorkflowError.ocrFailed(String(describing: error))
        }

        let observations = request.results ?? []
        // Vision boundingBox origin is bottom-left: higher Y = higher on screen.
        // Top-to-bottom, then left-to-right (story 49).
        let sorted = observations.sorted { lhs, rhs in
            let dy = lhs.boundingBox.origin.y - rhs.boundingBox.origin.y
            if abs(dy) > 0.001 { return dy > 0 }
            return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
        }
        let lines = sorted
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.isEmpty }
        return OCRResult(text: lines.joined(separator: "\n"), lines: lines)
    }
}
