/*
 Spatial Stash - Applied Container Banner

 Says which album or gallery the grid below is showing, and offers the way out.

 Opening a container from the Albums tab applies it as a filter — that is what
 lets the browser reuse the entire existing content path instead of becoming a
 second one. The cost of that choice is that the grid you land on looks like an
 ordinary filtered grid with nothing to say why, and no obvious way back to the
 whole library. This is that missing half: without it, "open an album" is a trip
 with no return.

 It is a *back* control, so it returns to the Albums tab as well as dropping the
 filter. An earlier version only dropped the filter and stayed on the grid, which
 read as broken: the one control on an album's grid, pressed to leave the album,
 left you exactly where you were with different contents.
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
                // Back, not just "clear". The first version dropped the filter
                // and stayed put, which is not what pressing the one control on
                // an album's grid means — you came from the browser and expect
                // to land back in it. So it does both: drops the container and
                // returns to Albums, where nothing is applied and every album is
                // there to pick from.
                Button {
                    appModel.clearAppliedContainer(isVideo: isVideo)
                    windowModel.selectedTab = .albums
                } label: {
                    Label("All \(containerKind.pluralTitle)", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }
}
