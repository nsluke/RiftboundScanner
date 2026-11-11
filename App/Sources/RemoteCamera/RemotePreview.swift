#if os(macOS)
import CoreGraphics
import Foundation
import SwiftUI

/// The iPhone app's live picture on the Mac (ADR-004): the newest JPEG frame,
/// decoded off the main actor, or none once the link drops. Runs for the
/// app's lifetime from the root view, since its frame stream can be read
/// only once.
@Observable
final class RemotePreviewModel {
    private(set) var image: CGImage?
    private let frames: AsyncStream<Data?>

    init(frames: AsyncStream<Data?>) {
        self.frames = frames
    }

    func run() async {
        for await jpeg in frames {
            guard let jpeg else {
                image = nil
                continue
            }
            if let decoded = try? await PhotoDecoder.decode(jpeg, maxPixelSize: 1600) {
                image = decoded
            }
        }
    }
}

/// Shows the iPhone app's picture, or that it is on its way.
struct RemotePreviewView: View {
    let model: RemotePreviewModel

    var body: some View {
        if let image = model.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView("Waiting for the iPhone's picture…")
                .tint(.white)
                .foregroundStyle(.white)
        }
    }
}
#endif
