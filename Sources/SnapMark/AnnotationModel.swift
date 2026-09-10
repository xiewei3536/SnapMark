import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Color model (value type for clean undo snapshots)

struct RGBA: Equatable, Codable {
    var r: Double, g: Double, b: Double, a: Double

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    static let presets: [RGBA] = [
        RGBA(r: 1.00, g: 0.23, b: 0.19, a: 1), // red
        RGBA(r: 1.00, g: 0.58, b: 0.00, a: 1), // orange
        RGBA(r: 1.00, g: 0.80, b: 0.00, a: 1), // yellow
        RGBA(r: 0.20, g: 0.78, b: 0.35, a: 1), // green
        RGBA(r: 0.00, g: 0.48, b: 1.00, a: 1), // blue
        RGBA(r: 0.42, g: 0.36, b: 0.98, a: 1), // violet
        RGBA(r: 1.00, g: 0.18, b: 0.33, a: 1), // pink
        RGBA(r: 0.10, g: 0.10, b: 0.12, a: 1), // black
        RGBA(r: 1.00, g: 1.00, b: 1.00, a: 1), // white
    ]
}

// MARK: - Tools & annotations

enum Tool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, line, arrow, rect, ellipse, text, mosaic, badge, crop
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "t.square" // "textformat" is a localized glyph (格式 in Chinese)
        case .mosaic: return "mosaic"
        case .badge: return "1.circle.fill"
        case .crop: return "crop"
        }
    }

    var labelKey: String { "tool.\(rawValue)" }

    var shortcutKey: Character? {
        switch self {
        case .select: return "v"
        case .pen: return "p"
        case .highlighter: return "h"
        case .line: return "l"
        case .arrow: return "a"
        case .rect: return "r"
        case .ellipse: return "e"
        case .text: return "t"
        case .mosaic: return "m"
        case .badge: return "b"
        case .crop: return "c"
        }
    }
}

enum TextAlign: String, CaseIterable, Equatable {
    case left, center, right
    var ns: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

/// Typography for text annotations. `fontFamily == nil` means the system font.
struct TextStyle: Equatable {
    var fontFamily: String? = nil
    var bold: Bool = true
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var alignment: TextAlign = .left
    var plate: Bool = false    // contrasting rounded backdrop behind the text
    var outline: Bool = false  // contrasting stroke around the glyphs
    var shadow: Bool = true

    /// Resolves the NSFont for a pixel size. Returns `syntheticItalic == true` when italics were
    /// requested but the family has no italic face; callers then apply `.obliqueness` — never a
    /// font matrix (`NSFont(descriptor:textTransform:)` silently drops the point size).
    func resolvedFont(size: CGFloat) -> (font: NSFont, syntheticItalic: Bool) {
        let fm = NSFontManager.shared
        var font: NSFont
        if let family = fontFamily {
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            font = fm.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
                ?? fm.font(withFamily: family, traits: bold ? [.boldFontMask] : [], weight: bold ? 9 : 5, size: size)
                ?? fm.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        } else {
            font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if italic {
                let converted = fm.convert(font, toHaveTrait: .italicFontMask)
                if converted.fontDescriptor.symbolicTraits.contains(.italic) { font = converted }
            }
        }
        let hasItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
        return (font, italic && !hasItalic)
    }

    func font(size: CGFloat) -> NSFont { resolvedFont(size: size).font }
}

/// One drawn element. All coordinates are in image PIXEL space, top-left origin.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable { case pen, highlighter, line, arrow, rect, ellipse, text, mosaic, badge }

    var id = UUID()
    var kind: Kind
    var color: RGBA = RGBA.presets[0]
    var lineWidth: CGFloat = 8
    var points: [CGPoint] = []
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var text: String = ""
    var fontSize: CGFloat = 44
    var textStyle = TextStyle()
    var badgeNumber: Int = 1
    var mosaicBlur: Bool = false

    var shapeRect: CGRect { CGRect(corner: start, corner: end) }

    var badgeRadius: CGFloat { 14 + lineWidth * 1.6 }

    // MARK: Text

    /// Inner padding between the glyphs and the text box (also the plate's corner radius).
    var textPadding: CGFloat { max(4, fontSize * 0.18) }

    var isLightColor: Bool { color.r * 0.299 + color.g * 0.587 + color.b * 0.114 > 0.6 }

    /// A color that reads against the text color (for plates and outlines).
    var textContrastColor: NSColor {
        isLightColor ? NSColor.black.withAlphaComponent(0.88) : NSColor.white.withAlphaComponent(0.96)
    }

    /// Plate color: the opposite of the text color.
    var plateColor: NSColor {
        isLightColor ? NSColor.black.withAlphaComponent(0.62) : NSColor.white.withAlphaComponent(0.86)
    }

    /// Outline color: contrasts with whatever sits directly behind the glyphs.
    var outlineColor: NSColor {
        if textStyle.plate {
            // On a white plate use a dark outline, on a dark plate a light one.
            return isLightColor ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.75)
        }
        return textContrastColor
    }

    /// The fully styled text (fill pass), in pixel units.
    func attributedText() -> NSAttributedString {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes(strokeOnly: false))
    }

    /// Stroke-only pass drawn underneath the fill so the outline sits outside the glyphs.
    func outlineAttributedText() -> NSAttributedString {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes(strokeOnly: true))
    }

    private func textAttributes(strokeOnly: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textStyle.alignment.ns
        let resolved = textStyle.resolvedFont(size: fontSize)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolved.font,
            .foregroundColor: color.nsColor,
            .paragraphStyle: paragraph,
        ]
        if resolved.syntheticItalic { attrs[.obliqueness] = 0.22 }
        if textStyle.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if textStyle.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if strokeOnly {
            attrs[.strokeColor] = outlineColor
            attrs[.strokeWidth] = 7.0 // positive = stroke only; % of font size, half lands outside the glyph
            attrs[.foregroundColor] = outlineColor
            attrs[.underlineColor] = NSColor.clear
            attrs[.strikethroughColor] = NSColor.clear
            return attrs
        }
        if textStyle.shadow && !textStyle.plate {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = fontSize * 0.08
            shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.04)
            attrs[.shadow] = shadow
        }
        return attrs
    }

    /// Size of the text box (glyphs + padding), in pixels. Multi-line aware.
    func measuredTextSize() -> CGSize {
        let rect = attributedText().boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width) + textPadding * 2, height: ceil(rect.height) + textPadding * 2)
    }

    var textBox: CGRect { CGRect(origin: start, size: measuredTextSize()) }

    /// Bounding box in pixel space (for hit-testing / selection chrome).
    var bounds: CGRect {
        switch kind {
        case .pen, .highlighter, .mosaic:
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            let pad = effectiveStrokeWidth / 2 + 4
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
        case .line, .arrow:
            return CGRect(corner: start, corner: end).insetBy(dx: -lineWidth - 8, dy: -lineWidth - 8)
        case .rect, .ellipse:
            return shapeRect.insetBy(dx: -lineWidth / 2 - 4, dy: -lineWidth / 2 - 4)
        case .text:
            let size = measuredTextSize()
            return CGRect(origin: start, size: size).insetBy(dx: -4, dy: -4)
        case .badge:
            let r = badgeRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2).insetBy(dx: -4, dy: -4)
        }
    }

    var effectiveStrokeWidth: CGFloat {
        switch kind {
        case .highlighter: return lineWidth * 3
        case .mosaic: return lineWidth * 4.5
        default: return lineWidth
        }
    }

    mutating func translate(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
        for i in points.indices {
            points[i].x += delta.x
            points[i].y += delta.y
        }
    }
}

// MARK: - Renderer (shared by the live canvas and the flattened export)

/// Draws annotations into a CGContext whose coordinate space is image pixels, top-left origin (flipped).
enum AnnotationRenderer {

    static func render(_ annotations: [Annotation], in ctx: CGContext,
                       imageSize: CGSize, pixelated: CGImage?, blurred: CGImage?) {
        for a in annotations {
            render(a, in: ctx, imageSize: imageSize, pixelated: pixelated, blurred: blurred)
        }
    }

    static func render(_ a: Annotation, in ctx: CGContext,
                       imageSize: CGSize, pixelated: CGImage?, blurred: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch a.kind {
        case .pen:
            strokeSmoothPath(a.points, in: ctx, color: a.color.cgColor, width: a.lineWidth, blend: .normal)
        case .highlighter:
            strokeSmoothPath(a.points, in: ctx, color: a.color.withAlpha(0.45).cgColor,
                             width: a.effectiveStrokeWidth, blend: .multiply)
        case .line:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .arrow:
            drawArrow(from: a.start, to: a.end, color: a.color.cgColor, width: a.lineWidth, in: ctx)
        case .rect:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineJoin(.round)
            let r = min(6, a.lineWidth)
            ctx.addPath(CGPath(roundedRect: a.shapeRect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
        case .ellipse:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokeEllipse(in: a.shapeRect)
        case .text:
            drawText(a, in: ctx)
        case .mosaic:
            drawMosaic(a, in: ctx, imageSize: imageSize, pixelated: pixelated, blurred: blurred)
        case .badge:
            drawBadge(a, in: ctx)
        }
    }

    // MARK: primitives

    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func strokeSmoothPath(_ points: [CGPoint], in ctx: CGContext,
                                         color: CGColor, width: CGFloat, blend: CGBlendMode) {
        guard !points.isEmpty else { return }
        ctx.setBlendMode(blend)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(smoothPath(points))
        ctx.strokePath()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint,
                                  color: CGColor, width: CGFloat, in ctx: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let angle = atan2(dy, dx)
        let headLen = max(14, width * 3.2)
        let headWidth = headLen * 0.72

        // Shaft stops where the head begins.
        let shaftEnd = CGPoint(x: end.x - cos(angle) * headLen * 0.8, y: end.y - sin(angle) * headLen * 0.8)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        // Head.
        let left = CGPoint(x: end.x - cos(angle) * headLen - sin(angle) * headWidth / 2,
                           y: end.y - sin(angle) * headLen + cos(angle) * headWidth / 2)
        let right = CGPoint(x: end.x - cos(angle) * headLen + sin(angle) * headWidth / 2,
                            y: end.y - sin(angle) * headLen - cos(angle) * headWidth / 2)
        ctx.setFillColor(color)
        ctx.move(to: end)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        let box = a.textBox
        if a.textStyle.plate {
            let plate = NSBezierPath(roundedRect: box, xRadius: a.textPadding, yRadius: a.textPadding)
            a.plateColor.setFill()
            plate.fill()
        }
        let textRect = box.insetBy(dx: a.textPadding, dy: a.textPadding)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        if a.textStyle.outline {
            a.outlineAttributedText().draw(with: textRect, options: options)
        }
        a.attributedText().draw(with: textRect, options: options)
    }

    private static func drawMosaic(_ a: Annotation, in ctx: CGContext, imageSize: CGSize,
                                   pixelated: CGImage?, blurred: CGImage?) {
        guard let overlay = a.mosaicBlur ? blurred : pixelated, !a.points.isEmpty else { return }
        let stroke = smoothPath(a.points).copy(strokingWithWidth: a.effectiveStrokeWidth,
                                               lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroke)
        ctx.clip()
        drawImageInFlippedContext(overlay, rect: CGRect(origin: .zero, size: imageSize), in: ctx)
    }

    private static func drawBadge(_ a: Annotation, in ctx: CGContext) {
        let r = a.badgeRadius
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: r * 0.25,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(max(2, r * 0.09))
        ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }
        let font = NSFont.systemFont(ofSize: r * 1.05, weight: .bold)
        let isLight = (a.color.r * 0.299 + a.color.g * 0.587 + a.color.b * 0.114) > 0.72
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isLight ? NSColor.black : NSColor.white,
        ]
        let str = NSAttributedString(string: "\(a.badgeNumber)", attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
    }

    /// Draws a CGImage upright inside a flipped (top-left origin) context.
    static func drawImageInFlippedContext(_ image: CGImage, rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}

// MARK: - Filtered image cache (mosaic / blur sources)

final class FilteredImageCache {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private(set) var pixelated: CGImage?
    private(set) var blurred: CGImage?
    private var sourceID: ObjectIdentifier?

    func prepare(for image: CGImage) {
        let id = ObjectIdentifier(image)
        guard sourceID != id else { return }
        sourceID = id
        let ci = CIImage(cgImage: image)

        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = ci
        pixellate.scale = Float(max(12, min(image.width, image.height) / 55))
        pixellate.center = .zero
        if let out = pixellate.outputImage?.cropped(to: ci.extent) {
            pixelated = Self.ciContext.createCGImage(out, from: ci.extent)
        }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ci.clampedToExtent()
        blur.radius = Float(max(10, min(image.width, image.height) / 90))
        if let out = blur.outputImage?.cropped(to: ci.extent) {
            blurred = Self.ciContext.createCGImage(out, from: ci.extent)
        }
    }
}

// MARK: - Hit testing (used by the editor's select tool)

extension Annotation {
    /// Precise hit test against the drawn geometry, in image pixels.
    func hits(_ p: CGPoint, tolerance tol: CGFloat) -> Bool {
        switch kind {
        case .pen, .highlighter, .mosaic:
            return Self.distanceToPolyline(p, points) <= effectiveStrokeWidth / 2 + tol
        case .line:
            return Self.distanceToSegment(p, start, end) <= lineWidth / 2 + tol
        case .arrow:
            let head = max(14, lineWidth * 3.2)
            let nearHead = hypot(p.x - end.x, p.y - end.y) <= head * 0.8 + tol
            return nearHead || Self.distanceToSegment(p, start, end) <= lineWidth / 2 + tol
        case .rect:
            let band = lineWidth / 2 + tol
            let outer = shapeRect.insetBy(dx: -band, dy: -band)
            let inner = shapeRect.insetBy(dx: band, dy: band)
            let insideInner = inner.width > 0 && inner.height > 0 && inner.contains(p)
            return outer.contains(p) && !insideInner
        case .ellipse:
            let r = shapeRect
            guard r.width > 1, r.height > 1 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let d = sqrt(nx * nx + ny * ny) // 1.0 lies exactly on the ellipse
            let band = (lineWidth / 2 + tol) / min(rx, ry)
            return abs(d - 1) <= band
        case .text:
            return bounds.contains(p)
        case .badge:
            return hypot(p.x - start.x, p.y - start.y) <= badgeRadius + tol
        }
    }

    /// Loose hit test: accepts clicks inside closed shapes (fallback when nothing is hit precisely).
    func hitsLoosely(_ p: CGPoint) -> Bool {
        switch kind {
        case .rect, .ellipse: return shapeRect.contains(p)
        default: return false
        }
    }

    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    static func distanceToPolyline(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        if pts.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 0..<(pts.count - 1) {
            best = min(best, distanceToSegment(p, pts[i], pts[i + 1]))
        }
        return best
    }
}
