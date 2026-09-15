/*
 Hypnos - iOS compatibility layer

 The app was written for visionOS first, and a handful of visionOS-only SwiftUI
 and RealityKit APIs are used from dozens of files: ornaments, glass backgrounds,
 z-offsets, `ImagePresentationComponent`, the spatial-audio policy. Rather than
 sprinkle `#if os(visionOS)` through every view, this file gives iOS a same-name
 stand-in for each of them with the closest flat-screen meaning:

 - `.ornament(...)`            → an overlay pinned to the matching edge, in a
                                 horizontal scroller when it is wider than the
                                 screen (a phone in portrait is narrower than
                                 any of the viewer bars).
 - `.glassBackgroundEffect()`  → iOS 26 Liquid Glass (`.glassEffect`).
 - `.offset(z:)`               → no-op; there is no depth axis.
 - `ImagePresentationComponent`→ a null-object RealityKit component: every
                                 query answers "mono / unsupported", and both
                                 `Spatial3DImage` initialisers throw. The photo
                                 model's 3D paths therefore compile unchanged
                                 and simply fail closed. The UI never offers
                                 them on iOS (see `PlatformCapabilities`).
 - `applySpatialAudioPolicy()` → no-op; head-tracked spatial audio is a
                                 visionOS window-placement concern.

 Everything here is compiled **only on iOS**. The visionOS build sees the real
 APIs and nothing from this file, so it cannot change visionOS behaviour.

 `WindowGeometry` and `PlatformCapabilities` at the bottom are the two things
 that exist on both platforms: shared code calls them, and each platform
 supplies its own answer.
 */

import AVFoundation
import RealityKit
import SwiftUI
import UIKit

// MARK: - Shared: what this build can do

/// Feature availability that shared code branches on at runtime, so a single
/// view can hide a control instead of the whole file being duplicated.
enum PlatformCapabilities {
    #if os(visionOS)
    /// RealityKit's `ImagePresentationComponent` 2D→3D conversion.
    static let supportsSpatial3D = true
    /// `ImmersiveSpace` scenes (immersive photo mode, MV-HEVC video).
    static let supportsImmersiveSpaces = true
    /// Several independent windows that can be summoned, hidden and saved as
    /// groups. iOS has one window per scene and no summon.
    static let supportsMultipleWindows = true
    /// The real-time fake-3D stereo pipeline (`Pseudo3DStereoEngine`), which
    /// renders a per-eye pair — meaningless on a flat display.
    static let supportsStereoVideo = true
    /// Diorama: background-removed foreground popped forward in z.
    static let supportsDiorama = true
    /// Whether the app may resize its own window (`requestGeometryUpdate`).
    static let supportsWindowResizing = true
    #else
    static let supportsSpatial3D = false
    static let supportsImmersiveSpaces = false
    static let supportsMultipleWindows = false
    static let supportsStereoVideo = false
    static let supportsDiorama = false
    static let supportsWindowResizing = false
    #endif

    /// Marketing name of the device family, for copy that names the platform.
    @MainActor
    static var deviceFamilyName: String {
        #if os(visionOS)
        return "Apple Vision Pro"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

// MARK: - Shared: window geometry requests

/// The one place shared code asks the system to resize a window. visionOS
/// honours it through `UIWindowScene.GeometryPreferences.Vision`; iOS windows
/// are sized by the system, so the request is dropped.
@MainActor
enum WindowGeometry {
    enum ResizingRestriction: Equatable {
        /// Keep the window's aspect ratio while the user resizes it.
        case uniform
        /// Any size.
        case freeform
    }

    /// Request a new size and/or resizing restriction for `scene`.
    ///
    /// - Parameters:
    ///   - scene: the window scene to resize; nil is a no-op.
    ///   - size: the requested size, or nil to leave the size alone.
    ///   - restriction: the resizing restriction, or nil to leave it alone.
    ///   - animated: whether visionOS may animate the change. Most callers
    ///     want `false` so an aspect-fit resize snaps instead of gliding.
    static func request(
        _ scene: UIWindowScene?,
        size: CGSize? = nil,
        restriction: ResizingRestriction? = nil,
        animated: Bool = false
    ) {
        #if os(visionOS)
        guard let scene else { return }
        let preferences: UIWindowScene.GeometryPreferences.Vision
        switch (size, restriction) {
        case let (size?, restriction?):
            preferences = .init(size: size, resizingRestrictions: restriction.uiKitValue)
        case let (size?, nil):
            preferences = .init(size: size)
        case let (nil, restriction?):
            preferences = .init(resizingRestrictions: restriction.uiKitValue)
        case (nil, nil):
            return
        }
        if animated {
            scene.requestGeometryUpdate(preferences)
        } else {
            UIView.performWithoutAnimation {
                scene.requestGeometryUpdate(preferences)
            }
        }
        #else
        _ = (scene, size, restriction, animated)
        #endif
    }
}

#if os(visionOS)
private extension WindowGeometry.ResizingRestriction {
    var uiKitValue: UIWindowScene.ResizingRestrictions {
        switch self {
        case .uniform: return .uniform
        case .freeform: return .freeform
        }
    }
}
#endif

#if !os(visionOS)

// MARK: - iOS: ornaments become overlays

/// Stand-in for SwiftUI's `OrnamentAttachmentAnchor`. Only the `.scene(...)`
/// form is used in this app; the 3D anchor collapses to a 2D alignment.
struct OrnamentAttachmentAnchor {
    let alignment: Alignment

    struct SceneAnchor {
        let alignment: Alignment

        static let bottomFront = SceneAnchor(alignment: .bottom)
        static let bottom = SceneAnchor(alignment: .bottom)
        static let bottomBack = SceneAnchor(alignment: .bottom)
        static let topFront = SceneAnchor(alignment: .top)
        static let top = SceneAnchor(alignment: .top)
        static let topBack = SceneAnchor(alignment: .top)
        static let leading = SceneAnchor(alignment: .leading)
        static let leadingFront = SceneAnchor(alignment: .leading)
        static let trailing = SceneAnchor(alignment: .trailing)
        static let trailingFront = SceneAnchor(alignment: .trailing)
        static let center = SceneAnchor(alignment: .center)
    }

    static func scene(_ anchor: SceneAnchor) -> OrnamentAttachmentAnchor {
        OrnamentAttachmentAnchor(alignment: anchor.alignment)
    }
}

extension View {
    /// visionOS attaches an ornament outside the window; on iOS the same bar is
    /// laid over the content at the matching edge, inside the safe area.
    ///
    /// Bars wider than the view scroll horizontally rather than clipping —
    /// every viewer bar in this app is wider than an iPhone in portrait. A bar
    /// that wants to know about that scroll reads `\.ornamentIsScrolling`
    /// rather than attaching its own gesture; see the note on that key.
    func ornament<Content: View>(
        visibility: Visibility = .automatic,
        attachmentAnchor: OrnamentAttachmentAnchor,
        contentAlignment: Alignment = .center,
        @ViewBuilder ornament: () -> Content
    ) -> some View {
        let bar = ornament()
        // Every call site attaches to `.scene(...)`, i.e. the window — so the
        // iOS bar belongs at the screen's edge, not at the edge of whatever
        // the content happened to size itself to (a letterboxed photo would
        // otherwise float the bar across the middle of the display).
        return frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: attachmentAnchor.alignment) {
                if visibility != .hidden {
                    IOSOrnamentContainer(edgeAlignment: attachmentAnchor.alignment) {
                        bar
                    }
                    .transition(.opacity)
                }
            }
    }
}

/// Whether the ornament bar around this view is being scrolled horizontally.
///
/// It is published *down* from the scroller because a bar cannot detect the
/// drag itself: a `DragGesture(minimumDistance: 0)` attached to the scroller's
/// own content claims the touch at touch-down and the scroll view's pan never
/// begins, so every control past the screen edge becomes unreachable. Measured
/// on an iPhone 18 Pro Max, iOS 27: identical bars scrolled 171 points without
/// that gesture and 0 with it.
///
/// A bar that suppresses an auto-hide timer while the user is handling it
/// therefore observes this instead of adding a gesture of its own.
private struct OrnamentIsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ornamentIsScrolling: Bool {
        get { self[OrnamentIsScrollingKey.self] }
        set { self[OrnamentIsScrollingKey.self] = newValue }
    }
}

/// Hosts an ornament's content as an edge overlay. Its frame hugs the content,
/// so taps outside the bar still reach whatever is underneath.
private struct IOSOrnamentContainer<Content: View>: View {
    let edgeAlignment: Alignment
    @ViewBuilder let content: () -> Content
    @State private var isScrolling = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content()
            ScrollView(.horizontal) {
                content()
                    .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onScrollPhaseChange { _, phase in
                isScrolling = phase.isScrolling
            }
        }
        .environment(\.ornamentIsScrolling, isScrolling)
        .padding(.horizontal, 12)
        .padding(edgeAlignment == .top ? .top : .bottom, 8)
    }
}

// MARK: - iOS: glass

extension View {
    /// visionOS's window-glass backing. iOS 26 has Liquid Glass; the shape
    /// defaults to the rounded rectangle visionOS uses.
    func glassBackgroundEffect() -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func glassBackgroundEffect<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}

// MARK: - iOS: depth modifiers

extension View {
    /// There is no z axis on a flat display; layering is handled by ZStack order.
    func offset(z: CGFloat) -> some View {
        self
    }
}

// MARK: - iOS: ImagePresentationComponent null object

/// Null-object stand-in for RealityKit's visionOS-only spatial-photo component.
///
/// Exists so `PhotoWindowModel` and the views that read its 3D state compile
/// unchanged. Semantics: the component can be created and stored, but it has
/// no spatial content — `viewingMode` is always `.mono`, `aspectRatio(for:)`
/// is unknown, `supportedViewingModes` is empty, and every `Spatial3DImage`
/// initialiser throws `Spatial3DUnavailable`. Nothing in the iOS UI offers a
/// 3D mode (`PlatformCapabilities.supportsSpatial3D` is false), so these paths
/// are reachable only from persisted state and fail closed when they are.
struct ImagePresentationComponent: Component {
    enum ViewingMode: Hashable, Sendable {
        case mono
        case spatial3D
        case spatial3DImmersive
        case spatialStereo
        case spatialStereoImmersive
    }

    struct Spatial3DUnavailable: LocalizedError {
        var errorDescription: String? {
            "Spatial 3D conversion needs Apple Vision Pro."
        }
    }

    /// The generated-depth source. Cannot be constructed on iOS.
    final class Spatial3DImage: @unchecked Sendable {
        init(contentsOf url: URL) async throws {
            throw Spatial3DUnavailable()
        }

        init(imageSource: CGImageSource) async throws {
            throw Spatial3DUnavailable()
        }

        func generate() async throws {
            throw Spatial3DUnavailable()
        }
    }

    var desiredViewingMode: ViewingMode = .mono

    /// Always mono: nothing spatial can have been generated.
    var viewingMode: ViewingMode { .mono }

    /// Zero, the same value visionOS reports before a component has a size.
    var presentationScreenSize: SIMD2<Float> { .zero }

    init(spatial3DImage: Spatial3DImage) {}

    func aspectRatio(for mode: ViewingMode) -> Float? { nil }

    static func supportedViewingModes(for image: Spatial3DImage) -> Set<ViewingMode> { [] }
}

// MARK: - iOS: spatial audio policy

extension AVPlayerItem {
    /// visionOS restricts stereo spatialisation so audio does not anchor to
    /// the wrong window. iOS plays through the device or headphones as-is.
    /// `nonisolated` like the RAVEMedia original: callers run off the main
    /// actor (`ChunkBufferManager`).
    nonisolated func applySpatialAudioPolicy() {}
}

extension AVPlayer {
    nonisolated func applySpatialAudioPolicy(for asset: AVURLAsset) {}
}

#endif
