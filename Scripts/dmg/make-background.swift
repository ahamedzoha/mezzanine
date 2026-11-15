// Draws the installer window's background (640 × 440 pt, 1x and 2x) from Bias Light: a soft lilac
// glow behind the app (the lamp behind the screen), a lilac arrow to Applications, and the
// instruction top-left on the gutter (never centred). The wall is light, not graphite: Finder
// draws icon labels in dark text over a background picture whatever the appearance, and the
// owner's tab and path bars can cover the bottom of the window, so the words sit at the top.
// Run: swift Scripts/dmg/make-background.swift Scripts/dmg  (then tiffutil joins the two).
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "."
let size = CGSize(width: 640, height: 440)
// Icon centres as the DMG settings place them (Finder coordinates, y from the top).
let appCentre = CGPoint(x: 170, y: 220), appsCentre = CGPoint(x: 470, y: 220)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> Data {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Flip to Finder's coordinates (origin top-left).
    ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)

    // The wall: a pale warm grey, a touch darker towards the floor.
    let room = CGGradient(colorsSpace: nil, colors: [color(0xF5F4F7), color(0xE4E3E9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(room, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // The lamp: a soft lilac glow behind the app icon.
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xA08CFF, 0.42), color(0xA08CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: appCentre, startRadius: 0, endCenter: appCentre, endRadius: 150, options: [])

    // The arrow, between the two icons (128 pt icons; keep clear of them).
    ctx.setStrokeColor(color(0x7C68E8))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let y = appCentre.y, from = appCentre.x + 92, to = appsCentre.x - 92
    ctx.move(to: CGPoint(x: from, y: y)); ctx.addLine(to: CGPoint(x: to, y: y))
    ctx.move(to: CGPoint(x: to - 11, y: y - 9)); ctx.addLine(to: CGPoint(x: to, y: y)); ctx.addLine(to: CGPoint(x: to - 11, y: y + 9))
    ctx.strokePath()

    // The instruction, top-left on the 40 pt gutter.
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = ns
    let title = NSAttributedString(string: "Drag Mezzanine into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor(cgColor: color(0x1A1C20))!])
    let sub = NSAttributedString(string: "Updates arrive by themselves after that.", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(cgColor: color(0x1A1C20, 0.6))!])
    title.draw(at: CGPoint(x: 40, y: 30))
    sub.draw(at: CGPoint(x: 40, y: 52))
    NSGraphicsContext.restoreGraphicsState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = size   // 72 dpi at 1x, 144 at 2x
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))
print("wrote \(out)/background.png and background@2x.png")
