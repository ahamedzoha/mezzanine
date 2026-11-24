// Posters for demo titles without one (a still, its title set like a title card) and each title's
// UltraBlur colours (the four corners of its art), from what fetch.py saved.
// Usage: swift Scripts/demo/art.swift
import AppKit
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let art = root.appending(path: "build.noindex/demo/art")
let fontURL = root.appending(path: "Mezzanine/Resources/Fonts/BigShouldersDisplay.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
struct Title: Decodable { let id: String; let type: String; let title: String; let year: Int; let artOf: String?; let focus: Double? }
struct Library: Decodable { let titles: [Title] }
let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: root.appending(path: "Scripts/demo/library.json")))
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func image(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
func corners(_ img: CGImage) -> [String: String] {
    var px = [UInt8](repeating: 0, count: 2 * 2 * 4)
    let ctx = CGContext(data: &px, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 2, height: 2))
    func hex(_ i: Int) -> String { String(format: "%02x%02x%02x", px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) }
    return ["topLeft": hex(0), "topRight": hex(1), "bottomLeft": hex(2), "bottomRight": hex(3)]
}
func poster(_ t: Title, from img: CGImage, to url: URL) {
    let w = 800.0, h = 1200.0
    let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = max(w / Double(img.width), h / Double(img.height))
    let iw = Double(img.width) * scale, ih = Double(img.height) * scale
    ctx.interpolationQuality = .high
    // The part of the picture that matters, kept in frame.
    let x = min(0, max(w - iw, w / 2 - iw * (t.focus ?? 0.5)))
    ctx.draw(img, in: CGRect(x: x, y: (h - ih) / 2, width: iw, height: ih))
    let shade = CGGradient(colorsSpace: sRGB, colors: [CGColor(srgbRed: 0.055, green: 0.06, blue: 0.067, alpha: 0.94), CGColor(srgbRed: 0.055, green: 0.06, blue: 0.067, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: 720), options: [])
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    var size = 150.0
    let text = t.title.uppercased()
    func attr(_ s: Double) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineHeightMultiple = 0.86
        let d = NSFontDescriptor(fontAttributes: [.family: "Big Shoulders Display", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.heavy]])
        return NSAttributedString(string: text, attributes: [.font: NSFont(descriptor: d, size: s) ?? .systemFont(ofSize: s, weight: .heavy), .foregroundColor: NSColor(white: 0.95, alpha: 1), .paragraphStyle: style])
    }
    let longest = text.split(separator: " ").map(String.init).max { $0.count < $1.count } ?? text
    while NSAttributedString(string: longest, attributes: attr(size).attributes(at: 0, effectiveRange: nil)).size().width > 680 { size -= 4 }
    let box = attr(size).boundingRect(with: CGSize(width: 690, height: 800), options: [.usesLineFragmentOrigin])
    attr(size).draw(with: CGRect(x: 56, y: 285, width: 690, height: box.height), options: [.usesLineFragmentOrigin])
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.write(to: url)
}

var colours: [String: [String: String]] = [:]
for t in library.titles {
    guard let img = image(art.appending(path: "\(t.artOf ?? t.id)-art.jpg")) else { print("no art: \(t.id)"); continue }
    colours[t.id] = corners(img)
    let out = art.appending(path: "\(t.id)-poster.jpg")
    if t.type != "episode", !FileManager.default.fileExists(atPath: out.path) { poster(t, from: img, to: out); print("poster: \(t.id)") }
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(colours).write(to: art.appending(path: "colours.json"))
print("colours: \(colours.count)")
