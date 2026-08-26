/*
 Spatial Stash - Applied Container Banner

 Says which album or gallery the grid below is showing, and offers the way out.

 Opening a container from the Albums tab applies it as a filter — that is what
 lets the browser reuse the entire existing content path instead of becoming a
 second one. The cost of that choice is that the grid you land on looks like an
 ordinary filtered grid with nothing to say why, and no obvious way back to the
 whole library. This is that missing half: without it, "open an album" is a trip
 with no return.
 */

import SwiftUI

struct AppliedContainerBanner: View {
    let isVideo: Bool

    @Environment(AppModel.self) private var appModel

    /// The container currently filtering this media kind, if exactly one is.
    ///
    /// Only a single selection reads as "you are in this album". Several at once
    /// is a filter the user built in the Filters tab, and that tab is where it
    /// belongs — claiming to be "in" three albums would be worse than silence.
    private var appliedContainer: AutocompleteItem? {
        if appModel.effectiveLibrarySource == .stash {
            guard !isVideo else { return nil }
            let galleries = appModel.currentFilter.selectedGalleries
            return galleries.count == 1 ? galleries[0] : nil
        }
        let albums = isVideo
            ? appModel.currentVideoFilter.photosCriteria.selectedAlbums
            : appModel.currentFilter.photosCriteria.selectedAlbums
        return albums.count == 1 ? albums[0] : nil
    }

    var body: some View {
        if let appliedContainer {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
                Text(appliedContainer.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    appModel.clearAppliedContainer(isVideo: isVideo)
                } label: {
                    Label("Show All", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }
}
