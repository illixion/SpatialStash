/*
 Spatial Stash - Media Thumbnail

 A square thumbnail for any media URL the app can resolve.

 One view for every place a small preview is needed — filter chips, filter option
 rows, album covers — because `ImageLoader.loadThumbnail(from:)` already handles
 all three URL shapes involved: a synthetic `photos-asset:///` URL, a container
 file, and a server thumbnail. A per-source thumbnail view would be describing a
 difference that does not survive contact with the loader.

 With no URL and no placeholder symbol it renders nothing at all, so a chip for a
 dimension that has no covers lays out exactly as it would without one.
 */

import SwiftUI
import UIKit

struct MediaThumbnail: View {
    let url: URL?
    let side: CGFloat
    /// Drawn when there is no image. Nil means render nothing rather than an
    /// empty tile.
    var placeholderSymbol: String?

    @State private var image: UIImage?

    private var cornerRadius: CGFloat {
        side <= 48 ? 6 : 12
    }

    var body: some View {
        if url == nil && placeholderSymbol == nil {
            EmptyView()
        } else {
            tile
                .task(id: url) { await load() }
        }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.2))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let placeholderSymbol {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: max(16, side * 0.28)))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func load() async {
        guard let url else { return }
        image = nil
        // Oversampled: these are drawn at display scale and a 1:1 request looks
        // soft on device.
        image = await ImageLoader.shared.loadThumbnail(from: url, maxSize: side * 3)
    }
}
