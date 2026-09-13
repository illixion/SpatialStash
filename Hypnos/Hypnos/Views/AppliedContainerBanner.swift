/*
 Hypnos - Applied Container Banner

 Says which album or gallery the grid below is showing, and offers the way out.

 Opening a container from the Albums tab applies it as a filter — that is what
 lets the browser reuse the entire existing content path instead of becoming a
 second one. The cost of that choice is that the grid you land on looks like an
 ordinary filtered grid with nothing to say why, and no obvious way back to the
 whole library. This is that missing half: without it, "open an album" is a trip
 with no return.

 It is a *back* control and nothing more: it returns to the Albums tab and leaves
 the container applied, so the browser can show which one you were in. Two
 earlier versions got this wrong in opposite directions — one cleared the filter
 and stayed put, which read as broken; the next cleared it *and* navigated, which
 collapsed this banner and reloaded the grid while the tab was still crossfading,
 so the contents shifted and repainted on a view being faded out. Leaving a
 container is the browser's "All" card.
 */

import SwiftUI

struct AppliedContainerBanner: View {
    let isVideo: Bool

    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel

    /// The container currently filtering this media kind, if exactly one is.
    ///
    /// Only a single selection reads as "you are in this album". Several at once
    /// is a filter the user built in the Filters tab, and that tab is where it
    /// belongs — claiming to be "in" three albums would be worse than silence.
    private var appliedContainer: AutocompleteItem? {
        if appModel.effectiveLibrarySource == .stash {
            let containers = isVideo
                ? appModel.currentVideoFilter.selectedGroups
                : appModel.currentFilter.selectedGalleries
            return containers.count == 1 ? containers[0] : nil
        }
        let albums = isVideo
            ? appModel.currentVideoFilter.photosCriteria.selectedAlbums
            : appModel.currentFilter.photosCriteria.selectedAlbums
        return albums.count == 1 ? albums[0] : nil
    }

    /// What the library calls what you are inside of — an album, a gallery, or
    /// for Stash's videos a group.
    private var containerKind: MediaContainer.Kind {
        .inLibrary(appModel.effectiveLibrarySource, isVideo: isVideo)
    }

    var body: some View {
        if let appliedContainer {
            HStack(spacing: 12) {
                Image(systemName: containerKind.symbolName)
                    .foregroundStyle(.secondary)
                Text(appliedContainer.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                // Purely navigational: it goes back to the browser and leaves
                // the container applied.
                //
                // It used to also clear the filter, which looked worse than it
                // sounds. Clearing collapses this banner and reloads the grid
                // while the tab is still crossfading, so the contents shifted up
                // and repainted on a view the user was watching disappear. And
                // it is not needed: the browser's own "All" card is how you leave
                // a container, and leaving this one applied is what lets the
                // browser show you where you were.
                Button {
                    windowModel.selectedTab = .albums
                } label: {
                    Label(containerKind.pluralTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }
}
