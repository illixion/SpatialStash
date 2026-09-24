/*
 Hypnos - macOS photo viewer window

 The `photo-detail` window's content: a single full-size image, loaded
 through the same `ImageLoader` (and so the same `MediaAuthorization`) every
 other platform's photo path uses. No adjustments, no 3D — none of
 `PhotoDisplayView`'s RealityKit/Metal-view machinery is reused here,
 deliberately (see `Hypnos/CLAUDE.md` "macOS"): this is a plain image in its
 own window, the Mac equivalent of `TVPhotoViewerView`'s "no chrome beyond the
 platform's own dismiss" scope.
 */

#if os(macOS)

import SwiftUI

struct MacPhotoViewerWindow: View {
    let value: MacPhotoWindowValue
    @State private var image: PlatformImage?
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isLoading {
                ProgressView()
            } else if failed {
                ContentUnavailableView(
                    "Can't Load This Image",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The image couldn't be downloaded or decoded.")
                )
            }
        }
        .navigationTitle(value.title ?? "Photo")
        .task {
            image = try? await ImageLoader.shared.loadImage(from: value.fullSizeURL)
            isLoading = false
            failed = image == nil
        }
    }
}

#endif
