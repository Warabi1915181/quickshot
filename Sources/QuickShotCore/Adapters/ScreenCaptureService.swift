import CoreGraphics
import Foundation
import ScreenCaptureKit

// Coordinate contract for this file:
// - `windowID(under:)` / `windowFrame(for:)` return and accept **Cocoa global points**
//   (origin bottom-left of the primary display). CG window bounds are flipped here
//   so selection UI can draw with AppKit unflipped.
// - `cropToCapture(_:rect:)` takes a Cocoa global rect (v1: main display at origin 0,0)
//   and crops `frame` pixels (CGImage origin top-left).
//
// Capture is ScreenCaptureKit only. CGDisplayCreateImage / CGWindowListCreateImage
// are obsoleted at macOS 15 and will not link on this SDK.

/// Live `CaptureServicing` backed by ScreenCaptureKit (`SCScreenshotManager`).
/// Permission: Screen Recording (`CGPreflightScreenCaptureAccess`).
/// Cursor: `SCScreenshotConfiguration.showsCursor`.
/// Window shadow: `SCScreenshotConfiguration.ignoreShadows`
///   (`includeShadow == true` → larger canvas with drop shadow;
///    `includeShadow == false` → tight window bounds only).
final class ScreenCaptureService: CaptureServicing, @unchecked Sendable {

    // MARK: - Permission

    func hasCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestCapturePermission() async -> Bool {
        // Shows the system Screen Recording prompt. May return false until relaunch.
        let granted = CGRequestScreenCaptureAccess()
        return granted || CGPreflightScreenCaptureAccess()
    }

    // MARK: - Capture

    func captureDisplay(includePointer: Bool) async throws -> CapturedImage {
        try ensurePermission()
        let content = try await shareableContent()
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first
        else {
            throw WorkflowError.captureFailed("no display available")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCScreenshotConfiguration()
        config.showsCursor = includePointer
        return try await screenshot(filter: filter, config: config)
    }

    func captureWindow(
        id: CGWindowID,
        includeShadow: Bool,
        includePointer: Bool
    ) async throws -> CapturedImage {
        try ensurePermission()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw WorkflowError.captureFailed("window \(id) not found")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCScreenshotConfiguration()
        config.showsCursor = includePointer
        // ignoreShadows == true → ignore framing (tight bounds, no drop shadow).
        // ignoreShadows == false → image includes the window's drop shadow (larger canvas).
        config.ignoreShadows = !includeShadow
        config.includeChildWindows = true
        return try await screenshot(filter: filter, config: config)
    }

    // MARK: - Crop

    /// Crop `rect` (Cocoa global points, origin bottom-left) out of `frame`.
    /// Pure geometry — no pixel capture. v1 assumes the main display (origin 0,0).
    ///
    ///   imageY = (frameHeightPoints - rect.origin.y - rect.height) * (pixel/point)
    func cropToCapture(_ frame: CapturedImage, rect: CGRect) throws -> CapturedImage {
        let pixelWidth = CGFloat(frame.pixelWidth)
        let pixelHeight = CGFloat(frame.pixelHeight)
        guard pixelWidth > 0, pixelHeight > 0, !rect.isNull, rect.width > 0, rect.height > 0 else {
            throw WorkflowError.captureFailed("empty crop")
        }

        // Main display point size. Retina: pixels = points * scale.
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let frameWidthPoints = displayBounds.width > 0 ? displayBounds.width : pixelWidth
        let frameHeightPoints = displayBounds.height > 0 ? displayBounds.height : pixelHeight
        let scaleX = pixelWidth / frameWidthPoints
        let scaleY = pixelHeight / frameHeightPoints

        // Frame-local (still bottom-left), then flip to CGImage top-left pixels.
        let localX = rect.origin.x - displayBounds.origin.x
        let localYFromBottom = rect.origin.y - displayBounds.origin.y
        let imageYPoints = frameHeightPoints - localYFromBottom - rect.height

        let pixelCrop = CGRect(
            x: (localX * scaleX).rounded(.down),
            y: (imageYPoints * scaleY).rounded(.down),
            width: (rect.width * scaleX).rounded(.up),
            height: (rect.height * scaleY).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        guard pixelCrop.width >= 1, pixelCrop.height >= 1,
              let cropped = frame.cgImage.cropping(to: pixelCrop)
        else {
            throw WorkflowError.captureFailed("empty crop")
        }
        return CapturedImage(cgImage: cropped)
    }

    // MARK: - Window hit testing (Cocoa global points)

    /// Topmost normal on-screen window (layer 0) whose Cocoa bounds contain `globalPoint`.
    /// Skips overlay/status/desktop layers so our selection chrome is never hit.
    func windowID(under globalPoint: CGPoint) -> CGWindowID? {
        guard let info = windowInfoList() else { return nil }
        for window in info {
            guard let number = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let cocoaBounds = cocoaBounds(of: window),
                  cocoaBounds.contains(globalPoint)
            else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    /// Window frame in Cocoa global points (bottom-left origin), for outlining (story 13).
    func windowFrame(for id: CGWindowID) -> CGRect? {
        guard let info = windowInfoList() else { return nil }
        for window in info {
            guard let number = window[kCGWindowNumber as String] as? Int,
                  CGWindowID(number) == id
            else { continue }
            return cocoaBounds(of: window)
        }
        return nil
    }

    // MARK: - Private

    private func ensurePermission() throws {
        guard hasCapturePermission() else {
            throw WorkflowError.capturePermissionDenied
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.current
        } catch {
            throw WorkflowError.captureFailed(String(describing: error))
        }
    }

    private func screenshot(
        filter: SCContentFilter,
        config: SCScreenshotConfiguration
    ) async throws -> CapturedImage {
        do {
            let output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: config
            )
            if let image = output.sdrImage {
                return CapturedImage(cgImage: image)
            }
            if let image = output.hdrImage {
                return CapturedImage(cgImage: image)
            }
            throw WorkflowError.captureFailed("empty screenshot output")
        } catch let error as WorkflowError {
            throw error
        } catch {
            // Fallback: macOS 14 captureImage + SCStreamConfiguration (cursor only; no shadow flag).
            do {
                let streamConfig = SCStreamConfiguration()
                streamConfig.showsCursor = config.showsCursor
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: streamConfig
                )
                return CapturedImage(cgImage: image)
            } catch {
                throw WorkflowError.captureFailed(String(describing: error))
            }
        }
    }

    private func windowInfoList() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
    }

    /// kCGWindowBounds (CG global, top-left origin) → Cocoa global (bottom-left origin).
    private func cocoaBounds(of window: [String: Any]) -> CGRect? {
        guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
              let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let flipHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: cgBounds.origin.x,
            y: flipHeight - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }
}
