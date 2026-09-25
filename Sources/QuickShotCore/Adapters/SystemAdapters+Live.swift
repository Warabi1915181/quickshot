import Foundation

/// Factory for live system adapters + image renderer.
public enum LiveServices {
    public static func make() -> (adapters: SystemAdapters, renderer: ImageRenderer) {
        let renderer = ImageRenderer()
        let adapters = SystemAdapters(
            capture: ScreenCaptureService(),
            ocr: VisionOCRService(),
            clipboard: PasteboardService(),
            files: FileService(),
            shortcuts: CarbonShortcutService()
        )
        return (adapters, renderer)
    }
}

public extension SystemAdapters {
    static func live(renderer: ImageRenderer = ImageRenderer()) -> (SystemAdapters, ImageRendering) {
        let adapters = SystemAdapters(
            capture: ScreenCaptureService(),
            ocr: VisionOCRService(),
            clipboard: PasteboardService(),
            files: FileService(),
            shortcuts: CarbonShortcutService()
        )
        return (adapters, renderer)
    }
}
