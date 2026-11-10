import RiftboundRecognizer
import SwiftUI

/// Reference art from the catalog's CDN URL, for this personal test build only;
/// a distributed app must source art through Riot's API. `nil` (a printing
/// the server knows and this build's bundle does not) shows the placeholder.
///
/// Landscape art (Battlefields) is turned a quarter-turn to fill a portrait
/// frame, the way the card itself lies on the feeder; scaled to fit upright
/// it would be a sliver beside the scan.
struct CardArtView: View {
    let url: URL?
    var size = CGSize(width: 50, height: 70)
    var orientation: Card.Orientation = .portrait

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                if turnsArt {
                    image.resizable().scaledToFit()
                        .frame(width: size.height, height: size.width)
                        .rotationEffect(.degrees(90))
                } else {
                    image.resizable().scaledToFit()
                }
            case .failure:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            case .empty:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
            @unknown default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    /// Only landscape art in a portrait frame is turned.
    private var turnsArt: Bool {
        orientation == .landscape && size.height > size.width
    }
}
