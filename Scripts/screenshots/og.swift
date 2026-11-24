// The website's link preview, 1200×630: the headline over Home. Usage: swift og.swift home.png out.jpg
import AppKit
import CoreText
let a = CommandLine.arguments
let root = URL(fileURLWithPath: a[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
CTFontManagerRegisterFontsForURL(root.appending(path: "Mezzanine/Resources/Fonts/BigShouldersDisplay.ttf") as CFURL, .process, nil)
let shot = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = 1200.0, h = 630.0, s = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ x: UInt32, _ al: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(x >> 16 & 255) / 255, green: CGFloat(x >> 8 & 255) / 255, blue: CGFloat(x & 255) / 255, alpha: al) }
let g = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: s, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
g.setFillColor(c(0x0E0F11)); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
g.drawRadialGradient(CGGradient(colorsSpace: s, colors: [c(0x584B47, 0.95), c(0x584B47, 0)] as CFArray, locations: [0, 1])!, startCenter: CGPoint(x: 820, y: 280), startRadius: 0, endCenter: CGPoint(x: 820, y: 280), endRadius: 720, options: [])
let iw = 900.0, ih = iw * Double(shot.height) / Double(shot.width)
g.interpolationQuality = .high
g.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: c(0, 0.6))
g.draw(shot, in: CGRect(x: 400, y: h - 250 - ih, width: iw, height: ih))
g.setShadow(offset: .zero, blur: 0, color: nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: false)
let d = NSFontDescriptor(fontAttributes: [.family: "Big Shoulders Display", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.heavy]])
let st = NSMutableParagraphStyle(); st.lineHeightMultiple = 0.84
NSAttributedString(string: "An evening with\nyour Plex library.", attributes: [.font: NSFont(descriptor: d, size: 92)!, .foregroundColor: NSColor(white: 0.95, alpha: 1), .paragraphStyle: st]).draw(with: CGRect(x: 56, y: 400, width: 900, height: 190), options: [.usesLineFragmentOrigin])
NSAttributedString(string: "Mezzanine", attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor(white: 0.95, alpha: 1)]).draw(at: CGPoint(x: 58, y: 300))
NSAttributedString(string: "a Mac app for Plex", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor(white: 0.95, alpha: 0.75)]).draw(at: CGPoint(x: 58, y: 264))
try NSBitmapImageRep(cgImage: g.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.86])!.write(to: URL(fileURLWithPath: a[2]))
