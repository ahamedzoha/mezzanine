import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// ImageIO decoding at the size an image is shown, off the main actor.
/// A 4K screenshot decoded for a 320-point card would cost ~33 MB; decoded
/// at its displayed size it's ~1 MB.
public enum Downsampler {
    /// Pixel sizes requests are rounded up to, so nearby sizes share entries.
    static let buckets = [128, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096]

    /// Largest bucket whose derivative is worth keeping on disk. Bigger
    /// requests (the image viewer, a fullscreen backdrop) stay in memory only.
    static let maxDiskBucket = 1024

    public static func bucket(for pixels: Int) -> Int {
        buckets.first { $0 >= pixels } ?? buckets.last!
    }

    /// Decodes `data` so its longest side is at most `maxPixel`.
    public static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
                return image
            }
        }
        // SVG studio logos and other formats ImageIO doesn't read.
        return rasterizeWithAppKit(data, maxPixel: maxPixel)
    }

    /// Re-encodes a decoded derivative for the disk cache: JPEG for opaque
    /// images, PNG when there's alpha (logos must stay transparent).
    public static func encode(_ image: CGImage) -> Data? {
        let hasAlpha: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func rasterizeWithAppKit(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(maxPixel) / max(image.size.width, image.size.height)
        var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
