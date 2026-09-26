import CoreGraphics
import CoreText
import XCTest
@testable import QuickShotCore

final class VisionOCRServiceTests: XCTestCase {
    func testRecognizesEnglishText() async throws {
        let result = try await VisionOCRService().recognize(
            in: textImage("QuickShot recognizes text", width: 800, height: 160, fontSize: 36), region: nil
        )
        XCTAssertEqual(result.text, "QuickShot recognizes text")
    }

    func testRecognizesSmallTextOnLargeImage() async throws {
        let result = try await VisionOCRService().recognize(
            in: textImage("Recognize small text", width: 1600, height: 1200, fontSize: 16), region: nil
        )
        XCTAssertEqual(result.text, "Recognize small text")
    }

    func testRecognizesChineseText() async throws {
        let result = try await VisionOCRService().recognize(
            in: textImage("截图识别文字", width: 800, height: 160, fontSize: 36), region: nil
        )
        XCTAssertEqual(result.text, "截图识别文字")
    }

    private func textImage(_ text: String, width: Int, height: Int, fontSize: CGFloat) -> CapturedImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 30, y: CGFloat(height) - fontSize - 30)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return CapturedImage(cgImage: context.makeImage()!)
    }
}
