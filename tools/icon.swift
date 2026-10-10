// Draws the app icon: the artwork in tools/icon-art.png (a finished icon, but opaque on a light background) clipped to the
// macOS icon grid's squircle, with a drop shadow. Run: swift tools/icon.swift out.png   (1024×1024; build.sh makes AppIcon.icns)
import AppKit

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // y down, like a design tool

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func fill(_ path: CGPath, _ c: CGColor) { ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath() }
// The macOS icon body: 824×824 at 100 pt margins. A superellipse (n = 5) matches Apple's continuous-corner
// rounded rect (radius 185.4) to within a pixel, and has no circular-arc "corners" that look off next to system icons.
func squircle() -> CGPath {
    let p = CGMutablePath(), a: CGFloat = 412, n: CGFloat = 5
    for i in 0..<720 {
        let t = CGFloat(i) / 720 * 2 * .pi, c = cos(t), s = sin(t)
        let pt = CGPoint(x: 512 + a * copysign(pow(abs(c), 2 / n), c), y: 512 + a * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

// Body with a soft drop shadow (CG shadow offsets are y-up); the artwork then covers the body entirely.
let base = squircle()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3))
fill(base, rgb(0xFFFFFF))
ctx.restoreGState()
ctx.addPath(base); ctx.clip()

// The artwork's own body (its own shadow around it) is ~1100 px wide, centred at (626, 620) in a 1254 px image. Map that centre
// onto ours and scale the body to 3% more than 824 so the clip stays inside it everywhere: the corners are not exactly ours.
let artURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("icon-art.png")
let art = NSBitmapImageRep(data: try! Data(contentsOf: artURL))!.cgImage!
let scale: CGFloat = 824 * 1.03 / 1100, cx: CGFloat = 626, cy: CGFloat = 620
let rect = CGRect(x: 512 - cx * scale, y: 512 - cy * scale, width: CGFloat(art.width) * scale, height: CGFloat(art.height) * scale)
ctx.interpolationQuality = .high
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // images draw upright in y-up
ctx.draw(art, in: CGRect(x: rect.minX, y: S - rect.maxY, width: rect.width, height: rect.height))

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"))
