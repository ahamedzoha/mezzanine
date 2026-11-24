// Frames a window capture for the README: rounded corners, a graphite backdrop with a soft lilac
// glow and a shadow (Bias Light), 2000 px wide. Usage: swift frame.swift in.png out.jpg
// Captures use invented server and profile names (-PublicNames YES), so nothing needs blurring.
import AppKit

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
guard let rep0 = NSBitmapImageRep(data: try Data(contentsOf: input)), let windowCG = rep0.cgImage else { fatalError("can't read \(input.path)") }

let pad: CGFloat = 70
// The window at a size that makes the whole picture 2000 px wide.
let w: CGFloat = 2000 - pad * 2
let h = (w * CGFloat(windowCG.height) / CGFloat(windowCG.width)).rounded()
let canvas = CGSize(width: w + pad * 2, height: h + pad * 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
// Graphite room, a touch lighter at the top.
let room = CGGradient(colorsSpace: space, colors: [color(0x1A1C20), color(0x0E0F11)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(room, start: CGPoint(x: 0, y: canvas.height), end: .zero, options: [])
// The bias light: a soft lilac glow behind the window's upper left.
let glow = CGGradient(colorsSpace: space, colors: [color(0xA08CFF, 0.20), color(0xA08CFF, 0)] as CFArray, locations: [0, 1])!
let centre = CGPoint(x: canvas.width * 0.3, y: canvas.height * 0.7)
ctx.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: canvas.width * 0.6, options: [])

let frame = CGRect(x: pad, y: pad, width: w, height: h)
let shape = CGPath(roundedRect: frame, cornerWidth: 20, cornerHeight: 20, transform: nil)
// Shadow under the window.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: color(0x000000, 0.65))
ctx.addPath(shape); ctx.setFillColor(color(0x0E0F11)); ctx.fillPath()
ctx.restoreGState()
// The window, clipped to its rounded corners (drops the desktop in the corners).
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(windowCG, in: frame)
ctx.restoreGState()
// A hairline edge, as macOS draws on dark windows.
ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 20, cornerHeight: 20, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(1); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!
try! data.write(to: output)
print("\(output.lastPathComponent): \(data.count / 1024) KB")
