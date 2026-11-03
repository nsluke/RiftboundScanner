import SwiftUI

/// Reference art from the catalog's CDN URL, for this personal test build only;
/// a distributed app must source art through Riot's API.
struct CardArtView: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
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
        .frame(width: 50, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}
