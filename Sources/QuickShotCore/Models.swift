import CoreGraphics
import Foundation

/// Opaque wrapper around a captured frame. Held by pending items and the annotator.
/// Unchecked Sendable: CGImage is immutable after capture.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }

    public var size: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }
}

public enum CaptureKind: String, Sendable, Equatable {
    case area
    case window
    case display
}

/// One completed screenshot awaiting user action. Owns exactly one thumbnail.
public struct PendingCapture: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var image: CapturedImage
    public var kind: CaptureKind
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        image: CapturedImage,
        kind: CaptureKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.image = image
        self.kind = kind
        self.createdAt = createdAt
    }

    public static func == (lhs: PendingCapture, rhs: PendingCapture) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.createdAt == rhs.createdAt
            && lhs.image.cgImage === rhs.image.cgImage
    }
}

// MARK: - Annotation

public enum AnnotationTool: String, Sendable, Equatable, CaseIterable {
    case arrow
    case text
    case rectangle
    case ellipse
    case highlight
    case blur
    case crop
}

/// RGBA stroke/fill color, 0...1 components. Platform-agnostic for tests.
public struct RGBAColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = RGBAColor(red: 0.92, green: 0.26, blue: 0.22)
    public static let orange = RGBAColor(red: 0.98, green: 0.58, blue: 0.12)
    public static let yellow = RGBAColor(red: 1.0, green: 0.8, blue: 0.0)
    public static let green = RGBAColor(red: 0.20, green: 0.70, blue: 0.30)
    public static let blue = RGBAColor(red: 0.16, green: 0.48, blue: 0.96)
    public static let purple = RGBAColor(red: 0.58, green: 0.32, blue: 0.90)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
}

/// Geometry is in image pixel coordinates, origin top-left.
public enum Mark: Identifiable, Sendable, Equatable {
    case arrow(id: UUID, start: CGPoint, end: CGPoint, color: RGBAColor, width: Double)
    case text(id: UUID, string: String, origin: CGPoint, color: RGBAColor, fontSize: Double)
    /// Transparent center, visible stroke (SPEC story 37).
    case rectangle(id: UUID, rect: CGRect, stroke: RGBAColor, strokeWidth: Double)
    case ellipse(id: UUID, rect: CGRect, stroke: RGBAColor, strokeWidth: Double)
    /// Attention without covering content (story 40).
    case highlight(id: UUID, rect: CGRect, color: RGBAColor)
    /// Conceal content (story 39).
    case blur(id: UUID, rect: CGRect, radius: Double)

    public var id: UUID {
        switch self {
        case let .arrow(id, _, _, _, _),
             let .text(id, _, _, _, _),
             let .rectangle(id, _, _, _),
             let .ellipse(id, _, _, _),
             let .highlight(id, _, _),
             let .blur(id, _, _):
            return id
        }
    }
}

/// In-memory annotation buffer. No project file format.
public struct AnnotatorDocument: Sendable, Equatable {
    public var baseImage: CapturedImage
    public var marks: [Mark]
    /// Crop in image pixel coordinates. `nil` = full image.
    public var crop: CGRect?

    public init(
        baseImage: CapturedImage,
        marks: [Mark] = [],
        crop: CGRect? = nil
    ) {
        self.baseImage = baseImage
        self.marks = marks
        self.crop = crop
    }
}

/// Snapshot of document used for undo/redo.
public struct DocumentSnapshot: Sendable, Equatable {
    public var marks: [Mark]
    public var crop: CGRect?

    public init(marks: [Mark], crop: CGRect?) {
        self.marks = marks
        self.crop = crop
    }
}

// MARK: - OCR

public struct OCRResult: Sendable, Equatable {
    /// Full text with line breaks preserved where recognition permits (story 49).
    public var text: String
    /// Individual recognized lines, top to bottom.
    public var lines: [String]

    public init(text: String, lines: [String]) {
        self.text = text
        self.lines = lines
    }
}

// MARK: - Preferences

public enum ThumbnailPosition: String, Sendable, Equatable, CaseIterable {
    case bottomLeading
    case bottomTrailing
    case topLeading
    case topTrailing
}

/// User preferences. Persisted by the app shell; core only stores values.
public struct AppPreferences: Sendable, Equatable {
    public var areaShortcut: KeyBinding
    public var displayShortcut: KeyBinding
    /// Optional in v1 (unbound by default).
    public var windowShortcut: KeyBinding?
    public var ocrShortcut: KeyBinding?
    public var thumbnailPosition: ThumbnailPosition
    /// Default false (story 17).
    public var includePointer: Bool
    /// Default true (story 15).
    public var includeWindowShadows: Bool

    public init(
        areaShortcut: KeyBinding = .areaCaptureDefault,
        displayShortcut: KeyBinding = .displayCaptureDefault,
        windowShortcut: KeyBinding? = nil,
        ocrShortcut: KeyBinding? = nil,
        thumbnailPosition: ThumbnailPosition = .bottomLeading,
        includePointer: Bool = false,
        includeWindowShadows: Bool = true
    ) {
        self.areaShortcut = areaShortcut
        self.displayShortcut = displayShortcut
        self.windowShortcut = windowShortcut
        self.ocrShortcut = ocrShortcut
        self.thumbnailPosition = thumbnailPosition
        self.includePointer = includePointer
        self.includeWindowShadows = includeWindowShadows
    }
}

// MARK: - Shortcut binding

public struct KeyBinding: Sendable, Equatable, Hashable {
    /// Carbon virtual key code.
    public var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘⇧4 — area capture (story 5). kVK_ANSI_4 = 0x15, cmdKey=0x100, shiftKey=0x200.
    public static let areaCaptureDefault = KeyBinding(keyCode: 0x15, modifiers: 0x100 | 0x200)
    /// ⌘⇧3 — full display (story 6). kVK_ANSI_3 = 0x14.
    public static let displayCaptureDefault = KeyBinding(keyCode: 0x14, modifiers: 0x100 | 0x200)
}

// MARK: - Errors

public enum WorkflowError: Error, Sendable, Equatable {
    case capturePermissionDenied
    case captureFailed(String)
    case ocrFailed(String)
    case copyFailed(String)
    case saveFailed(String)
    case dragFailed
    case shortcutConflict(String)
    case noActiveCapture

    /// User-visible message. Keep technical detail in the string when useful.
    public var message: String {
        switch self {
        case .capturePermissionDenied:
            return "Screen Recording access is required. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
        case let .captureFailed(detail):
            return "Capture failed. \(detail)"
        case let .ocrFailed(detail):
            return "Could not recognize text. \(detail)"
        case let .copyFailed(detail):
            return "Could not copy. \(detail)"
        case let .saveFailed(detail):
            return "Could not save. \(detail)"
        case .dragFailed:
            return "Drag did not complete. The capture is still available."
        case let .shortcutConflict(detail):
            return "Could not register shortcut. \(detail)"
        case .noActiveCapture:
            return "No capture is available."
        }
    }
}

// MARK: - Selection session (screen selection mode)

public enum SelectionMode: String, Sendable, Equatable {
    case area
    case window
    case ocrRegion
}

public struct SelectionSession: Sendable, Equatable {
    public var mode: SelectionMode
    /// Frozen full-display frame the user selects against (story 10).
    public var frozenFrame: CapturedImage
    /// Display bounds in global (Cocoa) coordinates for the frozen frame.
    public var displayBounds: CGRect

    public init(mode: SelectionMode, frozenFrame: CapturedImage, displayBounds: CGRect) {
        self.mode = mode
        self.frozenFrame = frozenFrame
        self.displayBounds = displayBounds
    }
}
