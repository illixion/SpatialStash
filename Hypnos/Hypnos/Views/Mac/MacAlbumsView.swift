/*
 Hypnos - macOS Albums section

 Mirrors `TVAlbumsTabView`: the same `MediaContainer` list (Stash galleries/
 groups, Photos albums/smart albums) the visionOS/iOS Albums tab shows.
 Opening one calls the same `AppModel.applyContainer(_:isVideo:)`, so paging,
 sort and the rest of the filter are the grid's, not a second pipeline; this
 view just also switches the sidebar selection to Pictures/Videos afterward.

 Local's nested folder browser (`LocalFolderBrowserView`) isn't ported here,
 same as tvOS — a real nested browser built for pointer/touch up/down-a-
 folder-stack taps, out of scope for this pass. See `Hypnos/CLAUDE.md` "macOS".
 */

#if os(macOS)

import SwiftUI

struct MacAlbumsView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: MacTab?
    @State private var isVideo = false

    private let gridSpacing: CGFloat = 20
    private let preferredCellSize: CGFloat = 200
    private let minColumns = 3

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $isVideo) {
                Text("Pictures").tag(false)
                Text("Videos").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.top, 12)

            content
        }
        .task(id: isVideo) {
            guard appModel.effectiveLibrarySource != .local else { return }
            await appModel.loadMediaContainers(isVideo: isVideo)
        }
    }

    @ViewBuilder
    private var content: some View {
        if appModel.effectiveLibrarySource == .local {
            ContentUnavailableView(
                "Browse Local Files in Pictures or Videos",
                systemImage: "folder",
                description: Text("The Local library's folder browser isn't available on the Mac app yet.")
            )
        } else if appModel.mediaContainers.isEmpty {
            ContentUnavailableView(
                "No \(containerKind.pluralTitle)",
                systemImage: containerKind.symbolName
            )
        } else {
            GeometryReader { geo in
                let layout = GridColumnLayout.resolve(
                    width: geo.size.width,
                    preferredCellSize: preferredCellSize,
                    minColumns: minColumns,
                    spacing: gridSpacing
                )
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                        ForEach(appModel.mediaContainers) { container in
                            Button {
                                appModel.applyContainer(container, isVideo: isVideo)
                                selection = isVideo ? .videos : .pictures
                            } label: {
                                VStack(spacing: 8) {
                                    MediaThumbnail(
                                        url: container.coverURL,
                                        side: layout.columnWidth,
                                        placeholderSymbol: container.kind.symbolName
                                    )
                                    Text(container.name)
                                        .lineLimit(1)
                                    Text("\(container.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var containerKind: MediaContainer.Kind {
        .inLibrary(appModel.effectiveLibrarySource, isVideo: isVideo)
    }
}

#endif
