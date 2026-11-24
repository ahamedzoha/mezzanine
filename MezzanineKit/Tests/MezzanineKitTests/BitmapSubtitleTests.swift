import CoreGraphics
import Testing
@testable import MezzanineKit

@Suite("Bitmap subtitle placement")
struct BitmapSubtitleTests {
    /// A line on a 1920 × 1080 disc canvas: 600 × 60, centred, its foot 60 px above the bottom.
    let line = CGRect(x: 660.0 / 1920, y: 960.0 / 1080, width: 600.0 / 1920, height: 60.0 / 1080)
    let disc = CGSize(width: 1920, height: 1080)

    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    @Test func ownSizeAndPlaceOnAFullFrame() {
        let r = BitmapSubtitle.rect(position: line, canvas: disc, coded: disc, display: disc, view: CGSize(width: 960, height: 540))
        #expect(near(r.width, 300) && near(r.height, 30) && near(r.minX, 330) && near(r.minY, 480))
        // An unknown canvas is the video's own frame.
        let same = BitmapSubtitle.rect(position: line, canvas: .zero, coded: disc, display: disc, view: CGSize(width: 960, height: 540))
        #expect(same == r)
    }

    /// The owner's film: cropped to 1920 × 800, so the disc's line sits in the bar below.
    @Test func croppedFilmUsesTheBar() {
        let film = CGSize(width: 1920, height: 800)
        let wide = BitmapSubtitle.rect(position: line, canvas: disc, coded: film, display: film, view: CGSize(width: 1920, height: 1080))
        #expect(near(wide.minY, 960) && near(wide.width, 600) && near(wide.height, 60))
        // In a window the film's own shape there's no bar: the line stays whole, on the picture.
        let tight = BitmapSubtitle.rect(position: line, canvas: disc, coded: film, display: film, view: film)
        #expect(near(tight.maxY, 784) && near(tight.height, 60))
    }

    @Test func anamorphicFollowsTheShownShape() {
        let r = BitmapSubtitle.rect(position: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1), canvas: CGSize(width: 720, height: 576),
                                    coded: CGSize(width: 720, height: 576), display: CGSize(width: 1024, height: 576),
                                    view: CGSize(width: 1024, height: 576))
        #expect(near(r.width, 512) && near(r.minX, 256) && near(r.minY, 460.8) && near(r.height, 57.6))
    }

    @Test func sizeGrowsAwayFromTheEdge() {
        let view = CGSize(width: 1920, height: 1080)
        let big = BitmapSubtitle.rect(position: line, canvas: disc, coded: disc, display: disc, view: view, scale: 2)
        #expect(near(big.maxY, 1020) && near(big.width, 1200) && near(big.midX, 960))
        let top = CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.05)
        let sign = BitmapSubtitle.rect(position: top, canvas: disc, coded: disc, display: disc, view: view, scale: 2)
        #expect(near(sign.minY, 54) && near(sign.height, 108))
    }

    /// Whatever the window, zoom or size, the line is whole and on screen.
    @Test func alwaysOnScreen() {
        for view in [CGSize(width: 340, height: 191), CGSize(width: 900, height: 600), CGSize(width: 600, height: 900), CGSize(width: 3024, height: 1964)] {
            for fills in [false, true] {
                for zoom in [1, 1.33] as [CGFloat] {
                    for scale in [0.6, 1, 2] as [CGFloat] {
                        for film in [disc, CGSize(width: 1920, height: 800), CGSize(width: 1440, height: 1080)] {
                            let r = BitmapSubtitle.rect(position: line, canvas: disc, coded: film, display: film, view: view,
                                                        fills: fills, zoom: zoom, scale: scale)
                            #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= view.width + 0.01 && r.maxY <= view.height + 0.01, "\(view) \(fills) \(zoom) \(scale)")
                            #expect(near(r.width / r.height, 10) || fills || zoom > 1 || film.width == 1440)
                        }
                    }
                }
            }
        }
        #expect(BitmapSubtitle.rect(position: .zero, canvas: disc, coded: disc, display: disc, view: disc) == .zero)
    }
}
