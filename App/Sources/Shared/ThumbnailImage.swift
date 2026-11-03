import CoreGraphics
import SwiftUI

/// A downsampled stored photo; the full 2048 px file never reaches a list row.
struct ThumbnailImage: View {
    let url: URL
    let maxPixelSize: Int

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) {
            image = await PhotoDecoder.thumbnail(at: url, maxPixelSize: maxPixelSize)
        }
    }
}
