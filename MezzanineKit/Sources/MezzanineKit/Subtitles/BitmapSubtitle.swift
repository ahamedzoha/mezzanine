import CoreGraphics

/// Where a bitmap subtitle (PGS, VobSub, DVB) goes on screen. The disc drew each line at a place
/// and size on a canvas of its own, often taller than the video: a 1920 × 1080 canvas on a film
/// cropped to 1920 × 800 puts its lines in the black bar below.
public enum BitmapSubtitle {
    /// - Parameters:
    ///   - position: the line's box on its canvas, 0 to 1.
    ///   - canvas: the canvas in the video's coded pixels; zero when it's the video's own frame.
    ///   - coded: the video's coded size.
    ///   - display: the video's shape as shown (differs from `coded` on anamorphic video).
    ///   - view: the space the subtitles may use.
    ///   - fills: the picture covers the view (edges cropped) instead of fitting inside it.
    ///   - zoom: the picture's extra scale (Zoom).
    ///   - scale: the viewer's subtitle size, about the line's outer edge.
    public static func rect(position: CGRect, canvas: CGSize, coded: CGSize, display: CGSize, view: CGSize,
                            fills: Bool = false, zoom: CGFloat = 1, scale: CGFloat = 1) -> CGRect {
        guard view.width > 0, view.height > 0, position.width > 0, position.height > 0 else { return .zero }
        let shape = display.width > 0 && display.height > 0 ? display : (coded.width > 0 && coded.height > 0 ? coded : view)
        let fit = (fills ? max : min)(view.width / shape.width, view.height / shape.height) * zoom
        let picture = CGRect(x: (view.width - shape.width * fit) / 2, y: (view.height - shape.height * fit) / 2,
                             width: shape.width * fit, height: shape.height * fit)

        // The canvas lies across the coded frame: as wide, centred vertically. Then both axes
        // follow the frame onto the picture (they only differ on anamorphic video).
        var area = picture
        if canvas.width > 0, canvas.height > 0, coded.width > 0, coded.height > 0 {
            let height = canvas.height * coded.width / canvas.width * picture.height / coded.height
            area = CGRect(x: picture.minX, y: picture.midY - height / 2, width: picture.width, height: height)
        }
        var box = CGRect(x: area.minX + position.minX * area.width, y: area.minY + position.minY * area.height,
                         width: position.width * area.width, height: position.height * area.height)

        // A bigger line grows away from the edge it sits by; it never outgrows the view.
        let size = min(scale, view.width * 0.96 / box.width, view.height * 0.5 / box.height)
        let low = box.midY >= view.height / 2
        box = CGRect(x: box.midX - box.width * size / 2, y: low ? box.maxY - box.height * size : box.minY,
                     width: box.width * size, height: box.height * size)

        // Cropped pictures and narrow windows: the line stays whole.
        let margin = view.height * 0.02
        box.origin.x = min(max(box.minX, view.width * 0.02), max(view.width * 0.02, view.width * 0.98 - box.width))
        box.origin.y = min(max(box.minY, margin), max(margin, view.height - margin - box.height))
        return box
    }
}
