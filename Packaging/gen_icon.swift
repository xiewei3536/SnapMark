// Generates AppIcon.icns: violet gradient rounded square with viewfinder + shutter glyph.
// Usage: swift gen_icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetPath = outDir + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> CGImage? {
    let s = CGFloat(pixels)
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // Rounded-square canvas (Big Sur style: content is ~80% with margin).
    let margin = s * 0.09
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035,
                  color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.36, green: 0.31, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.55, green: 0.30, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.78, green: 0.28, blue: 0.90, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Subtle top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Viewfinder brackets.
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let vf = rect.width * 0.56
    let arm = vf * 0.30
    let lw = rect.width * 0.055
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    let half = vf / 2
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: c.x - half + arm, y: c.y + half), CGPoint(x: c.x - half, y: c.y + half), CGPoint(x: c.x - half, y: c.y + half - arm)),
        (CGPoint(x: c.x + half - arm, y: c.y + half), CGPoint(x: c.x + half, y: c.y + half), CGPoint(x: c.x + half, y: c.y + half - arm)),
        (CGPoint(x: c.x - half + arm, y: c.y - half), CGPoint(x: c.x - half, y: c.y - half), CGPoint(x: c.x - half, y: c.y - half + arm)),
        (CGPoint(x: c.x + half - arm, y: c.y - half), CGPoint(x: c.x + half, y: c.y - half), CGPoint(x: c.x + half, y: c.y - half + arm)),
    ]
    for (a, b, d) in corners {
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.addLine(to: d)
        ctx.strokePath()
    }

    // Center shutter: ring + dot.
    let ringR = vf * 0.26
    ctx.setLineWidth(lw * 0.9)
    ctx.strokeEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    let dotR = ringR * 0.45
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2))

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    if let img = drawIcon(pixels: px) {
        writePNG(img, to: iconsetPath + "/" + name)
    }
}
print("iconset written to \(iconsetPath)")
