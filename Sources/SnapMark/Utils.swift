import AppKit
import UniformTypeIdentifiers

// MARK: - CGImage helpers

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }

    /// PNG data. Passing the backing scale embeds the DPI so Preview/Finder show the
    /// image at its real point size instead of 2× blown up.
    func pngData(scale: CGFloat = 1) -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        if scale > 1 {
            rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// JPEG data. Transparent areas (e.g. rounded window corners) are flattened onto white
    /// instead of turning black.
    func jpegData(quality: Double, scale: CGFloat = 1) -> Data? {
        let flattened = flattenedOntoWhite() ?? self
        let rep = NSBitmapImageRep(cgImage: flattened)
        if scale > 1 {
            rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func flattenedOntoWhite() -> CGImage? {
        guard alphaInfo != .none, alphaInfo != .noneSkipFirst, alphaInfo != .noneSkipLast else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    func nsImage(scale: CGFloat) -> NSImage {
        NSImage(cgImage: self, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

    /// Crops in pixel coordinates (top-left origin).
    func cropped(toPixels rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clamped.isEmpty else { return nil }
        return cropping(to: clamped)
    }
}

extension NSImage {
    var cgImageAnyScale: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Image files

enum ImageFile {
    /// Writes `image` to `url`, choosing PNG/JPEG from the extension. Returns false on failure.
    @discardableResult
    static func write(_ image: CapturedImage, to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let data: Data?
        if ext == "jpg" || ext == "jpeg" {
            data = image.cgImage.jpegData(quality: Settings.shared.jpegQuality, scale: image.scale)
        } else {
            data = image.cgImage.pngData(scale: image.scale)
        }
        guard let data else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("SnapMark: write failed \(url.path): \(error)")
            return false
        }
    }

    /// Saves to the user's capture folder using the current format & filename template.
    static func saveToCaptureFolder(_ image: CapturedImage) -> URL? {
        let settings = Settings.shared
        let url = settings.nextFileURL(ext: settings.imageFormat.fileExtension)
        return write(image, to: url) ? url : nil
    }
}

// MARK: - Clipboard

enum Clipboard {
    static func copy(image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image.nsImage(scale: scale)])
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }
}

// MARK: - Sounds

enum Sounds {
    static func playShutter() {
        guard Settings.shared.playSound else { return }
        NSSound(named: "Tink")?.play()
    }
    static func playDone() {
        guard Settings.shared.playSound else { return }
        NSSound(named: "Pop")?.play()
    }
}

// MARK: - Colors

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}

/// Brand accent, shared by AppKit and SwiftUI surfaces.
enum Brand {
    static let accent = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1)
    static let accentTop = NSColor(srgbRed: 0.45, green: 0.38, blue: 1.0, alpha: 1)
    static let accentBottom = NSColor(srgbRed: 0.62, green: 0.32, blue: 0.96, alpha: 1)
    static let recordRed = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.32, alpha: 1)
}

// MARK: - Coordinate conversion

enum ScreenMath {
    /// Height of the primary screen (the one containing the menu bar, Cocoa origin (0,0)).
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// Global Cocoa rect (bottom-left origin) → global CoreGraphics rect (top-left origin).
    static func cocoaToCG(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Global CoreGraphics rect (top-left origin) → global Cocoa rect (bottom-left origin).
    static func cgToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Key code display names

enum KeyNames {
    static let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        76: "⌤", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        map[keyCode] ?? "Key\(keyCode)"
    }
}

// MARK: - Misc

extension CGRect {
    /// Rect from two arbitrary corner points.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.down))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Wraps a closure so it can ride along in `NSMenuItem.representedObject`.
final class ClosureBox {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
}

extension NSMenu {
    /// Adds a menu item that runs a closure. The item's target is the menu-owning object
    /// passed as `owner`, which must implement `@objc func runClosure(_:)`.
    @discardableResult
    func addClosureItem(_ title: String, symbol: String? = nil, keyEquivalent: String = "",
                        modifiers: NSEvent.ModifierFlags = [.command], owner: AnyObject,
                        handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString("runClosure:"), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifiers
        item.target = owner
        item.representedObject = ClosureBox(handler)
        if let symbol {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            img?.isTemplate = true
            item.image = img
        }
        addItem(item)
        return item
    }
}
