import AppKit
import ScreenCaptureKit

struct CapturedImage {
    let cgImage: CGImage
    let scale: CGFloat // backing scale factor (pixels per point)

    var pointSize: CGSize {
        CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
    }
}

enum CaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case failed

    var errorDescription: String? {
        switch self {
        case .noPermission: return L("error.no_permission")
        case .displayNotFound: return L("error.display_not_found")
        case .failed: return L("error.capture_failed")
        }
    }
}

/// Still-image capture built on ScreenCaptureKit.
enum CaptureEngine {

    /// True when the app holds the Screen Recording permission.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission prompt (first run) or returns immediately.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Captures a full-resolution frozen image of the given screen, excluding SnapMark's own windows.
    static func captureDisplay(screen: NSScreen, showCursor: Bool = false) async throws -> CapturedImage {
        let displayID = ScreenMath.displayID(of: screen)
        let scale = screen.backingScaleFactor

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let ourWindows = content.windows.filter {
            $0.owningApplication?.processID == pid_t(ProcessInfo.processInfo.processIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingWindows: ourWindows)

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        if #available(macOS 14.0, *) {
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                return CapturedImage(cgImage: image, scale: scale)
            } catch {
                throw CaptureError.failed
            }
        } else {
            // macOS 13 fallback.
            guard let image = legacyCapture(displayID: displayID) else { throw CaptureError.failed }
            return CapturedImage(cgImage: image, scale: scale)
        }
    }

    /// Captures a single window at full resolution.
    static func captureWindow(windowID: CGWindowID) async throws -> CapturedImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.failed
        }
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(ScreenMath.cgToCocoa(window.frame)) })?
            .backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true // clean edges; the frame is exactly the window
        }

        if #available(macOS 14.0, *) {
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                return CapturedImage(cgImage: image, scale: scale)
            } catch {
                throw CaptureError.failed
            }
        } else {
            guard let image = legacyWindowCapture(windowID: windowID) else { throw CaptureError.failed }
            return CapturedImage(cgImage: image, scale: scale)
        }
    }

    // MARK: - macOS 13 fallbacks (CoreGraphics)

    private static func legacyCapture(displayID: CGDirectDisplayID) -> CGImage? {
        #if compiler(>=5.9)
        // CGDisplayCreateImage is deprecated from macOS 15 but remains the correct 13.x fallback.
        return CGDisplayCreateImage(displayID)
        #else
        return nil
        #endif
    }

    private static func legacyWindowCapture(windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                [.boundsIgnoreFraming, .bestResolution])
    }
}

// MARK: - On-screen window info (for window snapping in the selection overlay)

struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect // global Cocoa coordinates (bottom-left origin)
    let title: String
    let ownerName: String
    let layer: Int
}

enum WindowEnumerator {
    /// Lists normal on-screen windows, front-to-back, in global Cocoa coordinates.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != ourPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha > 0.05
            else { continue }
            let cgRect = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            guard cgRect.width >= 40, cgRect.height >= 40 else { continue }
            result.append(WindowInfo(
                windowID: windowID,
                frame: ScreenMath.cgToCocoa(cgRect),
                title: info[kCGWindowName as String] as? String ?? "",
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                layer: layer
            ))
        }
        return result
    }
}
