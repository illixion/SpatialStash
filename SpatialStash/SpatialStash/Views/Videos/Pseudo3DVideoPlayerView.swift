/*
 Spatial Stash - Pseudo 3D Video Player View

 Real-time "fake 3D" video in a normal (Shared Space) window — no immersive
 space, no MV-HEVC pre-compute. Architecture:

   AVPlayer (audio + master clock + transport + scrubbing + A-B loop)
        │  decoded mono frames via AVPlayerItemVideoOutput
        ▼
   StereoPump (dedicated background queue): warp the mono frame into LEFT +
        │  RIGHT eye buffers (videoPseudo3DEyeFragmentShader, cheap heuristic
        │  depth — see Pseudo3DSettings; depth source isolated for a future
        │  Core ML swap)
        ▼
   tagged CMReadySampleBuffer (.leftEye / .rightEye)
        ▼
   AVSampleBufferVideoRenderer ─▶ VideoPlayerComponent(.stereo) in a RealityView

 CRITICAL: all per-frame GPU work and enqueueing happens on a dedicated
 background queue with its own MTLCommandQueue — NEVER on the main thread. An
 earlier version pumped on the main actor and blocked it with
 waitUntilCompleted ~90×/s, which starved Core Animation commits (backboardd
 render-watchdog SIGKILL) and the main-queue AVPlayer prepare callbacks
 (mediaplaybackd async-prepare watchdog), taking down the whole compositor.

 The renderer's synchronizer free-runs at rate 1; each warped frame is tagged
 with a host-clock timestamp relative to that start, so AVPlayer stays the only
 clock governing audio/pause/seek and the sample-buffer renderer is purely a
 stereoscopic presentation surface. The eye pool is bounded (allocation
 threshold) and the pump is rate-capped so it can never flood the compositor.

 visionOS 26 APIs: CMReadySampleBuffer / CMTaggedDynamicBuffer / CVReadOnlyPixelBuffer.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import os
import QuartzCore
import RealityKit
import SwiftUI
import VideoToolbox

/// Diagnostics for the windowed-stereo pipeline. While `useStaticTestPattern`
/// is true, the engine bypasses AVPlayer and the Metal warp entirely and feeds
/// the renderer a static stereo test pattern built exactly like Apple's
/// "Rendering stereoscopic video with RealityKit" sample (420v buffers from a
/// pool merged with `recommendedPixelBufferAttributes`, proper format
/// description, pull-model enqueue). This isolates whether the windowed-stereo
/// plumbing itself is stable on-device before re-introducing our own decode/warp.
enum Pseudo3DDiagnostics {
    static let useStaticTestPattern = false
}

/// CPU mirror of the Metal `VideoStereoUniforms` struct (8 floats, 2 float2s at
/// offsets 32/40 matching Metal's float2 alignment, then 2 more floats).
private struct VideoStereoUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var depthStrength: Float
    var convergence: Float
    var eyeSign: Float
    var mirror: Float
    var useDepth: Float
    var depthUVScale: SIMD2<Float>
    var depthUVOffset: SIMD2<Float>
    var depthValueScale: Float
    var depthValueBias: Float
}

struct Pseudo3DVideoPlayerView: View {
    let videoURL: URL
    var isRoomActive: Bool = true
    /// When true (a menu/popover/sheet is open), recede the video plane within
    /// the RealityKit scene so it renders behind the presented chrome.
    var chromeOpen: Bool = false
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var settings: Pseudo3DSettings = .default
    /// Realtime inference vs. pre-processed cached depth.
    var depthMode: Pseudo3DDepthMode = .realtime
    /// Resume position (seconds) captured from the 2D player at engage time.
    var startAtSeconds: Double? = nil
    /// Engage without auto-playing: seek to `startAtSeconds` and warp that one
    /// frame (visibly playable in 3D) but don't start sustained playback. Used
    /// for a progressive engage mid-conversion so a second decode session
    /// doesn't fight the converter's reader; manual Play starts it.
    var startPaused: Bool = false
    var isFlipped: Bool = false
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    /// Initial mute state applied when a video loads (autoplay always starts
    /// playback; this only controls whether it opens with audio).
    var startMuted: Bool = true
    /// Restart from the top at end of playback. The video window always loops;
    /// the slideshow only loops clips shorter than its dwell interval (a longer
    /// clip plays through once and the server times the advance off its end).
    var loops: Bool = true
    /// Scene-space opacity for the video plane, applied via `OpacityComponent`.
    /// RealityKit content on visionOS ignores SwiftUI's `.opacity`, so a caller
    /// that crossfades (the slideshow) has to drive the fade through here.
    var contentOpacity: Double = 1
    /// Fired once per loaded item when its duration becomes known — the
    /// AVPlayer equivalent of the web player's `loadedmetadata`.
    var onDurationKnown: ((Double) -> Void)? = nil
    var onPlaybackError: (() -> Void)? = nil
    /// Tap on the video surface (toggles chrome) — handled as a RealityKit tap
    /// target because a 2D overlay can't catch gaze over a RealityView.
    var onToggleUI: (() -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @State private var engine = Pseudo3DStereoEngine()

    /// Distance (points) the video plane is pulled back toward the window
    /// glass. `.frame(depth: 0, alignment: .front)` pins the slab to the front
    /// of the window's depth region, which on-device reads ~9cm in front of
    /// the ornament / window-controls plane. Offsetting the whole assembly
    /// (slab + its clip volume, via .offset(z:) on the GeometryReader3D, so
    /// the internal fit math is unaffected) brings the video back to the
    /// chrome's plane. ~10 points/cm; tune on device — 0 restores the old
    /// front-of-region placement.
    private static let videoPlaneZRecess: CGFloat = 90

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                engine.configure(
                    visualAdjustments: visualAdjustments,
                    settings: settings,
                    isFlipped: isFlipped
                )
                engine.onVideoSizeKnown = onVideoSizeKnown
                engine.onPlaybackError = onPlaybackError
                engine.onDurationKnown = onDurationKnown
                engine.startMuted = startMuted
                engine.loops = loops
                engine.setContentOpacity(contentOpacity)
                content.add(engine.makeVideoEntity())
                engine.observeVideoSize(content: content)
                engine.load(url: videoURL, roomActive: isRoomActive, depthMode: depthMode, startAt: startAtSeconds, startPaused: startPaused)
            } update: { content in
                // Fit the video plane to the window (VideoPlayerComponent's screen
                // defaults to ~2× the window otherwise).
                let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                engine.updateViewBounds(bounds)
            }
            // Zero-depth slab keeps the video stable (nothing gets re-clipped
            // or culled). frame(depth:) defaults to .center alignment, which
            // parks the slab at the middle of the window's depth region — that
            // half-depth gap was the "Flip3D" recession. Align the slab to
            // .front; the videoPlaneZRecess offset below then pulls it back to
            // the ornament/window-controls plane (front of the depth region
            // measured ~9cm proud of the chrome on-device).
            .frame(depth: 0, alignment: .front)
            // Tapping the video toggles chrome. Targeted to the video entity's
            // tap-target collision (set up once the video size is known).
            .gesture(
                SpatialTapGesture()
                    .targetedToAnyEntity()
                    .onEnded { _ in onToggleUI?() }
            )
        }
        // Align the video plane with the chrome — see videoPlaneZRecess.
        .offset(z: -Self.videoPlaneZRecess)
        .onChange(of: videoURL) { _, newURL in
            engine.load(url: newURL, roomActive: isRoomActive, depthMode: depthMode)
        }
        .onChange(of: depthMode) { _, newMode in
            engine.setDepthMode(newMode)
        }
        // Real-time depth model switched (ViewMode menu or Settings): rebuild
        // the pump so the new model applies to THIS video immediately, keeping
        // position. (Cached playback is unaffected — its depth is baked.)
        .onChange(of: appModel.realtimeDepthModelName) { _, _ in
            if case .realtime = depthMode {
                engine.reloadDepthPipeline()
            }
        }
        .onAppear {
            engine.startMuted = startMuted
            engine.loops = loops
            engine.onDurationKnown = onDurationKnown
            engine.bindCommands(loopController: loopController, playbackModel: playbackModel)
            engine.configure(visualAdjustments: visualAdjustments, settings: settings, isFlipped: isFlipped)
            engine.setRoomActive(isRoomActive)
            engine.setChromeOpen(chromeOpen)
            engine.setContentOpacity(contentOpacity)
        }
        .onChange(of: loops) { _, new in
            engine.loops = new
        }
        .modifier(AnimatableSceneOpacity(opacity: contentOpacity) { [engine] value in
            engine.setContentOpacity(value)
        })
        .onChange(of: chromeOpen) { _, open in
            engine.setChromeOpen(open)
        }
        .onChange(of: visualAdjustments) { _, new in
            engine.configure(visualAdjustments: new, settings: settings, isFlipped: isFlipped)
        }
        .onChange(of: settings) { _, new in
            engine.configure(visualAdjustments: visualAdjustments, settings: new, isFlipped: isFlipped)
        }
        .onChange(of: isFlipped) { _, new in
            engine.configure(visualAdjustments: visualAdjustments, settings: settings, isFlipped: new)
        }
        .onChange(of: isRoomActive) { _, active in
            engine.setRoomActive(active)
        }
        .onDisappear {
            engine.cleanup()
        }
    }
}

/// Bridges a SwiftUI-animated opacity out to RealityKit. SwiftUI interpolates
/// `animatableData` frame-by-frame for the duration of the enclosing
/// `withAnimation`, so the callback sees the whole ramp; a plain
/// `.onChange(of:)` only ever observes the endpoints, which would turn a
/// crossfade into a cut to black. Needed because RealityKit content on visionOS
/// ignores SwiftUI's `.opacity` — the fade has to reach `OpacityComponent`.
private struct AnimatableSceneOpacity: ViewModifier, Animatable {
    var opacity: Double
    let apply: @MainActor (Double) -> Void

    /// `nonisolated` to satisfy `Animatable`, which SwiftUI drives from outside
    /// the main-actor-isolated `ViewModifier` surface. Animation ticks do run on
    /// the main thread, hence `assumeIsolated` rather than a hop (a hop would
    /// land after the tick it belongs to).
    nonisolated var animatableData: Double {
        get { opacity }
        set {
            opacity = newValue
            MainActor.assumeIsolated { apply(newValue) }
        }
    }

    func body(content: Content) -> some View { content }
}

// MARK: - Engine (main-actor: SwiftUI + transport only)

@MainActor
@Observable
final class Pseudo3DStereoEngine {
    // Presentation
    let videoRenderer = AVSampleBufferVideoRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var didStartSynchronizer = false

    // Source / clock
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var loadedURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var isRoomActive = true
    /// Playback state captured at room exit; room re-entry restores it so a
    /// manual pause survives focus/room flaps.
    private var wasPlayingBeforeRoomExit = true

    // Off-main frame pump (owns all per-frame GPU work).
    private var pump: StereoPump?
    // Diagnostic static-pattern pump (used when Pseudo3DDiagnostics.useStaticTestPattern).
    private var testPump: StereoTestPatternPump?

    // RealityView video entity + fit-to-window state. VideoPlayerComponent's
    // screen defaults to ~2× our window (Apple's sample scales it to fit), so we
    // scale the entity to the RealityView's bounds.
    @ObservationIgnored var videoEntity: Entity?
    @ObservationIgnored private var lastViewBounds: BoundingBox?
    @ObservationIgnored private var sizeSubscription: EventSubscription?
    @ObservationIgnored private var refitBurstTask: Task<Void, Never>?
    /// Decoded video dimensions from the pump's first frame — drives the
    /// content-aware fit (the component's screen mesh doesn't reflect them).
    @ObservationIgnored private var knownVideoSize: CGSize?
    @ObservationIgnored private var tapTargetInstalled = false
    /// While true, fade the video so an open menu/popover shows through it.
    @ObservationIgnored private var chromeOpen = false
    /// Video opacity while a menu/popover is open (low = chrome clearly visible).
    @ObservationIgnored private let chromeDimOpacity: Float = 0.12
    /// Caller-driven opacity (slideshow crossfades), multiplied with the chrome
    /// dim. SwiftUI's `.opacity` doesn't reach RealityKit content on visionOS.
    @ObservationIgnored private var contentOpacity: Float = 1

    // Config
    private var visualAdjustments = VisualAdjustments()
    private var settings = Pseudo3DSettings.default
    private var isFlipped = false
    /// Where depth comes from: realtime inference (~30Hz, held for in-between
    /// frames at 60fps video) or a pre-processed cache entry (exact PTS sync).
    /// Changing it reloads the pump.
    private var depthMode: Pseudo3DDepthMode = .realtime
    /// Physical width of the fitted video plane in meters (videoAspect × entity
    /// scale, tracked by fitVideo). Drives plane-size disparity normalization —
    /// see makePumpConfig.
    @ObservationIgnored private var planeWidthMeters: Float?

    // A-B loop
    private var loopA: Double?
    private var loopB: Double?

    /// Initial mute state applied to a freshly loaded player.
    @ObservationIgnored var startMuted = true
    /// Restart at the top when playback reaches the end.
    @ObservationIgnored var loops = true

    // Callbacks
    @ObservationIgnored var onVideoSizeKnown: ((CGSize) -> Void)?
    @ObservationIgnored var onPlaybackError: (() -> Void)?
    @ObservationIgnored var onDurationKnown: ((Double) -> Void)?
    /// One-shot latch for `onDurationKnown` (duration is polled from the
    /// periodic time observer, which fires ~30×/s). Reset per loaded item.
    @ObservationIgnored private var didReportDuration = false
    @ObservationIgnored private var onPlaybackUpdate: ((NativeMetalVideoPlayerView.Coordinator.PlaybackState) -> Void)?

    init() {
        synchronizer.addRenderer(videoRenderer)
    }

    // MARK: Entity

    func makeVideoEntity() -> Entity {
        let entity = Entity()
        var component = VideoPlayerComponent(videoRenderer: videoRenderer)
        component.desiredViewingMode = VideoPlaybackController.ViewingMode.stereo
        component.isPassthroughTintingEnabled = false
        entity.components.set(component)
        videoEntity = entity
        // Sync the fade state now the entity exists — setChromeOpen may have
        // fired (with the initial chromeOpen) before this, when videoEntity was
        // still nil. Applied here (once, at creation) rather than in refitVideo,
        // which runs on every layout/ornament change and wrongly re-tied the
        // opacity to ornament visibility.
        applyChromeOpacity()
        return entity
    }

    /// Subscribe to the video screen-size event so we re-fit once the plane has
    /// real dimensions (its visualBounds is empty until then). Call from the
    /// RealityView make closure where `content` is available.
    func observeVideoSize(content: RealityViewContent) {
        guard let entity = videoEntity else { return }
        sizeSubscription = content.subscribe(
            to: VideoPlayerEvents.VideoSizeDidChange.self, on: entity
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refitVideo() }
        }
    }

    /// Store the latest RealityView bounds (scene space) and fit to them.
    func updateViewBounds(_ bounds: BoundingBox) {
        lastViewBounds = bounds
        refitVideo()
    }

    private func refitVideo() {
        guard let bounds = lastViewBounds else { return }
        fitVideo(toViewBounds: bounds)
        installTapTarget()
    }

    /// Re-fit once the real video size is known (from the pump's first decoded
    /// frame) — fitVideo then scales from the video aspect, so the first pass
    /// fixes the size. The loop afterwards waits for the screen mesh to settle
    /// at its aspect-correct dims (it reads 1×1 until frames present, with no
    /// event on the change) and then rebuilds the tap target, which would
    /// otherwise keep the placeholder square's bounds; on timeout it rebuilds
    /// anyway (a square target is a harmless superset).
    private func scheduleRefitBurst() {
        refitBurstTask?.cancel()
        refitBurstTask = Task { [weak self] in
            guard let self else { return }
            let aspect = self.knownVideoSize.map { Float($0.width / max($0.height, 1)) }
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                self.refitVideo()
                if let entity = self.videoEntity, let aspect {
                    let ext = entity.visualBounds(relativeTo: entity).extents
                    if ext.x > 1e-4, ext.y > 1e-4, abs(ext.x / ext.y - aspect) < aspect * 0.02 {
                        break // mesh adopted the video dims
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            self.tapTargetInstalled = false
            self.installTapTarget()
        }
    }

    /// Give the video entity a collision shape + input target so a SpatialTapGesture
    /// can land on it (a 2D overlay can't catch gaze over a RealityView). Sized to
    /// the video plane in local space so the entity's fit-scale maps it correctly.
    private func installTapTarget() {
        guard let entity = videoEntity, !tapTargetInstalled else { return }
        let local = entity.visualBounds(relativeTo: entity)
        guard local.extents.x > 0.001, local.extents.y > 0.001 else { return }
        let box = ShapeResource.generateBox(
            width: local.extents.x, height: local.extents.y, depth: max(local.extents.z, 0.05)
        ).offsetBy(translation: local.center)
        entity.components.set(CollisionComponent(shapes: [box], isStatic: true))
        entity.components.set(InputTargetComponent())
        tapTargetInstalled = true
    }

    /// Scale the video entity so its plane fits within `bounds` (preserving
    /// aspect). Converges in one or two calls because it sets an absolute scale
    /// derived from the entity's unscaled size.
    private func fitVideo(toViewBounds bounds: BoundingBox) {
        guard let entity = videoEntity else { return }

        // Center the entity on the window plane. (Depth can't be used to dodge
        // an open menu — the zero-depth slab clips any off-plane entity, and a
        // SwiftUI .offset(z:) perturbs this fit; menu occlusion is handled by
        // fading the entity via OpacityComponent instead — see setChromeOpen.)
        entity.position = bounds.center

        let extents = entity.visualBounds(relativeTo: nil).extents
        let scale = entity.scale.x
        guard extents.x > 1e-4, extents.y > 1e-4, scale > 1e-4,
              bounds.extents.x > 1e-4, bounds.extents.y > 1e-4 else { return }
        let unscaledX = extents.x / scale
        let unscaledY = extents.y / scale
        // The component's screen mesh reads 1×1 until the first frames
        // present, then settles at (videoAspect × 1)m — with no fit trigger:
        // VideoSizeDidChange doesn't fire for renderer-backed components, so
        // any scale derived from *measured* mesh bounds is computed against
        // the stale square (observed on visionOS 26: tall videos ended up
        // undersized, wide ones cropped by ~the aspect ratio, depending on
        // which formula met the square). Derive the screen dims from the
        // pump-reported video aspect instead — (a, 1) in mesh-local meters —
        // and only fall back to measured bounds before the size is known.
        let target: Float
        if let size = knownVideoSize, size.width > 0, size.height > 0 {
            let videoAspect = Float(size.width / size.height)
            target = min(bounds.extents.x / videoAspect, bounds.extents.y)
        } else {
            target = min(bounds.extents.x / unscaledX, bounds.extents.y / unscaledY)
        }
        // Track the plane's physical width (the mesh is videoAspect × 1 m
        // pre-scale) and re-normalize disparity when it changes meaningfully.
        // Before the |target − scale| guard: the width must be known even when
        // the scale itself doesn't need re-applying.
        if let size = knownVideoSize, size.width > 0, size.height > 0,
           target.isFinite, target > 1e-4 {
            let width = Float(size.width / size.height) * target
            if abs((planeWidthMeters ?? 0) - width) > 0.01 {
                planeWidthMeters = width
                pump?.updateConfig(makePumpConfig())
            }
        }
        guard target.isFinite, target > 1e-4, abs(target - scale) > 0.02 else { return }
        AppLogger.videoWindow.info("fitVideo: bounds \(bounds.extents.x)x\(bounds.extents.y), mesh \(unscaledX)x\(unscaledY), videoAspect \(self.knownVideoSize.map { Float($0.width / $0.height) } ?? -1), scale \(scale) → \(target)")
        entity.scale = SIMD3<Float>(repeating: target)
    }

    // MARK: Config

    func configure(visualAdjustments: VisualAdjustments, settings: Pseudo3DSettings, isFlipped: Bool) {
        self.visualAdjustments = visualAdjustments
        self.settings = settings
        self.isFlipped = isFlipped
        pump?.updateConfig(makePumpConfig())
    }

    /// Fade/restore the video when a menu/popover opens/closes, so the presented
    /// chrome shows through the (front-plane) video instead of being occluded.
    func setChromeOpen(_ open: Bool) {
        chromeOpen = open
        applyChromeOpacity()
    }

    /// Caller-driven plane opacity (slideshow crossfade). Composes with the
    /// chrome dim rather than replacing it.
    func setContentOpacity(_ opacity: Double) {
        let clamped = Float(max(0, min(1, opacity)))
        guard abs(contentOpacity - clamped) > 0.001 else { return }
        contentOpacity = clamped
        applyChromeOpacity()
    }

    /// Reflect `chromeOpen` on the entity. Called from setChromeOpen AND after
    /// the entity is (re)fit, so the state is consistent even when the entity is
    /// created after the first setChromeOpen (which otherwise left it desynced —
    /// the first menu wouldn't fade, later ones would).
    private func applyChromeOpacity() {
        let opacity = contentOpacity * (chromeOpen ? chromeDimOpacity : 1.0)
        videoEntity?.components.set(OpacityComponent(opacity: opacity))
    }

    /// Plane width (meters) above which `depthStrength` is attenuated. The warp
    /// bakes disparity as a fraction of frame width, so the physical separation
    /// it demands of the eyes grows with the window — a Medium that fuses fine
    /// on a small window exceeds the ~1° vergence comfort zone on a large one.
    /// Attenuation-ONLY (min(1, ref/width)): a preset means at most its UV value,
    /// capped to a constant physical disparity once the plane exceeds the
    /// reference. Never amplify on small windows — an earlier symmetric version
    /// scaled small-window strength up into the 0.04 ceiling, which collapsed
    /// Medium and Strong into the same (excessive) disparity and re-amplified
    /// silhouette stairstepping.
    private static let referencePlaneWidthMeters: Float = 1.0

    private func makePumpConfig() -> StereoPump.Config {
        // Fixed at the (Subtle) default — persisted settings may carry a legacy
        // user-tuned strength, which is deliberately ignored (values above the
        // default don't fuse comfortably; see Pseudo3DSettings.depthStrength).
        var strength = Float(Pseudo3DSettings.default.depthStrength)
        if let planeWidth = planeWidthMeters, planeWidth > 0.05 {
            strength *= min(1, Self.referencePlaneWidthMeters / planeWidth)
        }
        return StereoPump.Config(
            brightness: Float(visualAdjustments.brightness),
            contrast: Float(visualAdjustments.contrast),
            saturation: Float(visualAdjustments.saturation),
            depthStrength: strength,
            convergence: Float(settings.convergence),
            autoConvergence: settings.autoConvergence,
            mirror: isFlipped
        )
    }

    func bindCommands(loopController: VideoLoopController?, playbackModel: VideoWindowModel?) {
        if let loopController {
            loopController.queryCurrentTime = { [weak self] in self?.currentTime }
            loopController.setLoopBounds = { [weak self] a, b in self?.setLoopBounds(a: a, b: b) }
        }
        if let playbackModel {
            playbackModel.playCommand = { [weak self] in self?.play() }
            playbackModel.pauseCommand = { [weak self] in self?.pause() }
            playbackModel.seekCommand = { [weak self] t in self?.seek(to: t) }
            playbackModel.setMutedCommand = { [weak self] m in self?.setMuted(m) }
            onPlaybackUpdate = { [weak playbackModel] state in
                playbackModel?.applyPlaybackState(
                    currentTime: state.currentTime,
                    duration: state.duration,
                    paused: state.paused,
                    muted: state.muted,
                    buffered: state.buffered
                )
            }
        }
    }

    // MARK: Load / transport

    var currentTime: Double { player?.currentTime().seconds ?? 0 }

    /// Switch depth mode; reloads the current video when it actually changes
    /// (the pump's depth source and tick rate are fixed at load time).
    func setDepthMode(_ mode: Pseudo3DDepthMode) {
        guard depthMode != mode else { return }
        depthMode = mode
        reloadDepthPipeline()
    }

    /// Rebuild the pump — and with it the depth provider / cache reader — for
    /// the currently loaded video, preserving position and pause state. Used
    /// when the preferred depth model changes so a switch applies to the video
    /// being watched, not just the next one opened.
    func reloadDepthPipeline() {
        guard let url = loadedURL else { return }
        let resumeTime = currentTime
        let wasPaused = player?.timeControlStatus == .paused
        let wasMuted = player?.isMuted ?? startMuted
        let savedLoopA = loopA
        let savedLoopB = loopB
        loadedURL = nil
        load(url: url, roomActive: isRoomActive)
        setLoopBounds(a: savedLoopA, b: savedLoopB)
        if resumeTime > 0 { seek(to: resumeTime) }
        if wasPaused { pause() }
        setMuted(wasMuted)
    }

    func load(url: URL, roomActive: Bool, depthMode requestedMode: Pseudo3DDepthMode? = nil, startAt: Double? = nil, startPaused: Bool = false) {
        if let requestedMode { depthMode = requestedMode }
        guard loadedURL != url else { return }

        // Cached mode plays back baked depth and needs no model; resolve its
        // entry up front (a missing/deleted cache falls back to realtime). A
        // still-converting entry is accepted too — progressive playback; the
        // reader follows the growing file.
        var cacheEntry: DepthCacheStore.Entry?
        if case .cached(let videoIdentity) = depthMode {
            cacheEntry = DepthCacheStore.entry(videoIdentity: videoIdentity)
            // A running conversion supersedes an older completed entry (e.g.
            // re-converting with a newly selected pre-process model): follow
            // the growing file so playback shows the depth just asked for.
            if DepthConversionManager.shared.isProcessing(videoIdentity: videoIdentity),
               let growing = DepthCacheStore.inProgressEntry(videoIdentity: videoIdentity) {
                cacheEntry = growing
            }
            if cacheEntry == nil {
                AppLogger.videoWindow.warning("Depth cache entry missing for \(videoIdentity, privacy: .private); falling back to realtime")
            }
        }

        // Fake-3D requires real depth — there is no heuristic fallback. Without
        // a cache entry or a model (e.g. a restored window whose model was since
        // deleted), fall back to the flat player rather than warping heuristically.
        guard Pseudo3DDiagnostics.useStaticTestPattern || cacheEntry != nil || CoreMLDepthProvider.hasAvailableModel(role: .realtime) else {
            Task { @MainActor in self.onPlaybackError?() }
            return
        }

        cleanupPlayer()
        loadedURL = url
        isRoomActive = roomActive
        knownVideoSize = nil
        refitBurstTask?.cancel()

        // Diagnostic: prove the windowed-stereo plumbing in isolation, no
        // AVPlayer / decode / warp. See Pseudo3DDiagnostics.
        if Pseudo3DDiagnostics.useStaticTestPattern {
            if !didStartSynchronizer {
                didStartSynchronizer = true
                synchronizer.setRate(1, time: .zero)
            }
            onVideoSizeKnown?(CGSize(width: 1280, height: 720))
            let pump = StereoTestPatternPump(videoRenderer: videoRenderer)
            pump.start()
            testPump = pump
            return
        }

        guard let renderer = MetalImageRenderer.shared else { return }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.applySpatialAudioPolicy()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.applySpatialAudioPolicy(for: asset)
        player.isMuted = startMuted
        player.automaticallyWaitsToMinimizeStalling = true

        self.player = player
        self.playerItem = item
        self.videoOutput = output

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Non-looping (slideshow clip longer than the dwell interval):
                // park on the last frame and let the caller time the advance.
                guard self.loops else {
                    self.reportPlaybackState()
                    return
                }
                self.seek(to: 0)
                if self.isRoomActive { self.play() }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPlaybackError?() }
        }
        // Load failures (bad URL/auth/TLS/container) set item.status = .failed
        // without ever firing FailedToPlayToEndTime — observe it so the caller's
        // fallback (flat player / 2D) engages instead of a silent black plane.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let message = observedItem.error?.localizedDescription ?? "unknown error"
            Task { @MainActor [weak self] in
                guard let self, self.playerItem === observedItem else { return }
                AppLogger.videoWindow.error("Pseudo-3D player item failed for \(self.loadedURL?.loggableDescription ?? "?", privacy: .public): \(message, privacy: .public)")
                self.onPlaybackError?()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTimeUpdate(time.seconds) }
        }

        // Start the renderer timeline once; frames are tagged relative to this.
        if !didStartSynchronizer {
            didStartSynchronizer = true
            synchronizer.setRate(1, time: .zero)
        }

        // Hand the pump everything it needs; it runs entirely off the main thread.
        let sizeCallback: @Sendable (CGSize) -> Void = { [weak self] size in
            Task { @MainActor in
                self?.knownVideoSize = size
                self?.onVideoSizeKnown?(size)
                self?.scheduleRefitBurst()
            }
        }
        // Cached depth: 60fps warp of pre-computed PTS-matched depth, no ANE.
        // Realtime: also 60fps video — RealtimeDepthSource infers at ~30Hz and
        // holds the map for the in-between frame (≤1 frame of depth age);
        // slow inference still gates its own tick, so this degrades to the
        // old 30fps cadence when the model can't keep up.
        let depthSource: PumpDepthSource?
        if let cacheEntry {
            depthSource = CachedDepthSource(entry: cacheEntry, device: renderer.device)
        } else {
            depthSource = RealtimeDepthSource(device: renderer.device)
        }
        let pump = StereoPump(
            videoRenderer: videoRenderer,
            output: output,
            renderer: renderer,
            startHostTime: CACurrentMediaTime(),
            depthSource: depthSource,
            frameInterval: 1.0 / 60.0,
            onVideoSizeKnown: sizeCallback
        )
        pump.updateConfig(makePumpConfig())
        pump.start()
        self.pump = pump

        // Resume where the previous (2D) player left off when the caller says
        // so — engaging fake-3D mid-watch shouldn't restart the video.
        if let startAt, startAt > 1 { seek(to: startAt) }
        // startPaused: seek alone (paused player) still delivers the target
        // frame to the video output, so the pump warps and enqueues that one
        // frame — the video shows as a 3D still without a sustained decode
        // session. Also clear the room-resume intent (defaults true) so a room
        // activation doesn't auto-play the still we deliberately left paused;
        // a manual play() still works normally.
        if startPaused {
            wasPlayingBeforeRoomExit = false
        } else if isRoomActive {
            play()
        }
    }

    func play() { isRoomActive = true; player?.play() }
    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        reportPlaybackState()
    }

    func setLoopBounds(a: Double?, b: Double?) { loopA = a; loopB = b }

    func setRoomActive(_ active: Bool) {
        guard isRoomActive != active else { return }
        isRoomActive = active
        if active {
            // Restore the state from room exit — a manual pause sticks across
            // focus/room flaps; a playing (e.g. wall-snapped) window resumes.
            if wasPlayingBeforeRoomExit { play() }
        } else {
            // `!= .paused`: a still-buffering player (.waitingToPlay…) counts
            // as playing, so the transient inactive flap at window open
            // doesn't capture it as "paused" and kill autoplay.
            wasPlayingBeforeRoomExit = player?.timeControlStatus != .paused
            pause()
        }
    }

    private func handleTimeUpdate(_ seconds: Double) {
        if let loopA, let loopB, seconds >= loopB - (1.0 / 60.0) { seek(to: loopA) }
        reportPlaybackState(currentTime: seconds)
    }

    private func reportPlaybackState(currentTime: Double? = nil) {
        guard let player else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let ranges = player.currentItem?.loadedTimeRanges ?? []
        let buffered = ranges
            .map(\.timeRangeValue)
            .map { $0.start.seconds + $0.duration.seconds }
            .filter { $0.isFinite }
            .max() ?? 0
        if !didReportDuration, duration.isFinite, duration > 0 {
            didReportDuration = true
            onDurationKnown?(duration)
        }
        onPlaybackUpdate?(
            .init(
                currentTime: currentTime ?? player.currentTime().seconds,
                duration: duration.isFinite ? duration : 0,
                paused: player.timeControlStatus != .playing,
                muted: player.isMuted,
                buffered: buffered
            )
        )
    }

    // MARK: Cleanup

    func cleanup() {
        sizeSubscription?.cancel()
        sizeSubscription = nil
        refitBurstTask?.cancel()
        refitBurstTask = nil
        videoEntity = nil
        lastViewBounds = nil
        tapTargetInstalled = false
        testPump?.stop()
        testPump = nil
        pump?.stop()
        pump = nil
        cleanupPlayer()
        videoRenderer.flush()
        onVideoSizeKnown = nil
        onPlaybackError = nil
        onDurationKnown = nil
        onPlaybackUpdate = nil
    }

    private func cleanupPlayer() {
        testPump?.stop()
        testPump = nil
        pump?.stop()
        pump = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        if let videoOutput { playerItem?.remove(videoOutput) }
        timeObserver = nil
        endObserver = nil
        failureObserver = nil
        player = nil
        playerItem = nil
        videoOutput = nil
        loadedURL = nil
        loopA = nil
        loopB = nil
        didReportDuration = false
    }
}

// MARK: - StereoPump (off-main: decode → warp → enqueue)

/// Owns all per-frame GPU work on a dedicated background queue with its own
/// command queue. `@unchecked Sendable`: the AVFoundation / CoreVideo / Metal
/// objects it holds are documented thread-safe, config is lock-guarded, and all
/// mutable state is touched only on `queue`.
final class StereoPump: @unchecked Sendable {
    struct Config {
        var brightness: Float = 0
        var contrast: Float = 1
        var saturation: Float = 1
        /// Matches Pseudo3DSettings' Subtle default — always overwritten by
        /// makePumpConfig, but a missed config path should fail conservative.
        var depthStrength: Float = 0.008
        var convergence: Float = 0.45
        /// Use the depth source's per-frame median as the zero-parallax plane
        /// when it provides one (cached mode); falls back to `convergence`.
        var autoConvergence: Bool = false
        var mirror: Bool = false
    }

    private let videoRenderer: AVSampleBufferVideoRenderer
    private let output: AVPlayerItemVideoOutput
    private let renderer: MetalImageRenderer
    private let commandQueue: MTLCommandQueue
    private let startHostTime: CFTimeInterval
    private let onVideoSizeKnown: @Sendable (CGSize) -> Void

    private let queue = DispatchQueue(label: "com.spatialstash.stereo-pump", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var textureCache: CVMetalTextureCache?
    /// BGRA Metal render targets for the warp (intermediate, not handed to the
    /// compositor).
    private var bgraPool: CVPixelBufferPool?
    /// 420v buffers handed to the renderer — built exactly like the validated
    /// test pattern (merged with `recommendedPixelBufferAttributes`).
    private var outPool: CVMutablePixelBuffer.Pool?
    private var poolWidth = 0
    private var poolHeight = 0
    /// Per-eye depth attachments for the occlusion-correct mesh warp ([0]=left,
    /// [1]=right). Separate textures because both eyes render in one command
    /// buffer; sharing one depth attachment let the right eye (2nd pass) test
    /// against the left eye's geometry, warping it more than the left.
    /// Multisampled + memoryless when MSAA is on (tile memory only, no backing).
    private var eyeDepthTextures: [MTLTexture?] = [nil, nil]
    /// Per-eye multisampled color targets for the MSAA mesh pass, resolved into
    /// the eye buffer by the render pass. Memoryless — only the resolve output
    /// (the eye buffer itself) is ever stored.
    private var eyeMSAAColorTextures: [MTLTexture?] = [nil, nil]
    /// Converts the BGRA warp output into the compositor's native 420v format.
    private let transferSession: VTPixelTransferSession
    /// Per-frame depth: realtime inference or PTS-matched cached depth (nil →
    /// heuristic warp only, e.g. a restored window whose model vanished).
    private let depthSource: PumpDepthSource?
    private var lastReportedSize: CGSize?
    /// When the depth source last transitioned unavailable → available; drives
    /// the flat→3D strength ramp in flatten mode (cached seek gaps, startup).
    private var depthResumeTime: CFTimeInterval?

    private let configLock = NSLock()
    private var config = Config()

    private let signposter = AppLogger.pseudo3DSignposter

    /// Tick rate: 60fps in both modes — the warp is only a few ms, so the pump
    /// follows the source up to 60. Cached mode looks depth up by PTS; realtime
    /// mode infers at ~30Hz and holds the map for the in-between frame (see
    /// RealtimeDepthSource), with a slow inference gating its own tick so the
    /// cadence self-throttles. Either way a tick only enqueues when a genuinely
    /// new decoded frame exists.
    private let frameInterval: Double
    /// Seconds to ramp depth strength back after a flat gap (avoids a 3D "pop").
    private let depthRampDuration: Double = 0.15
    /// Bounds in-flight eye buffers so a stalled compositor can never make the
    /// pool allocate IOSurfaces without limit.
    private let maxInFlightBuffers = 8

    init(
        videoRenderer: AVSampleBufferVideoRenderer,
        output: AVPlayerItemVideoOutput,
        renderer: MetalImageRenderer,
        startHostTime: CFTimeInterval,
        depthSource: PumpDepthSource?,
        frameInterval: Double,
        onVideoSizeKnown: @escaping @Sendable (CGSize) -> Void
    ) {
        self.videoRenderer = videoRenderer
        self.output = output
        self.renderer = renderer
        self.commandQueue = renderer.device.makeCommandQueue() ?? renderer.commandQueue
        self.startHostTime = startHostTime
        self.depthSource = depthSource
        self.frameInterval = frameInterval
        self.onVideoSizeKnown = onVideoSizeKnown
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        self.transferSession = session!
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &textureCache)
    }

    func updateConfig(_ newConfig: Config) {
        configLock.lock()
        config = newConfig
        configLock.unlock()
    }

    private func currentConfig() -> Config {
        configLock.lock(); defer { configLock.unlock() }
        return config
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: frameInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // Drain on the pump queue so no tick races teardown.
        queue.async { [weak self] in
            guard let self else { return }
            depthSource?.invalidate()
            if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
            self.bgraPool = nil
            self.outPool = nil
            self.eyeDepthTextures = [nil, nil]
            self.eyeMSAAColorTextures = [nil, nil]
        }
    }

    // MARK: Per-frame work (always on `queue`)

    private func tick() {
        guard videoRenderer.isReadyForMoreMediaData, let textureCache else { return }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let src = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        reportSizeIfNeeded(src)

        // Tag relative to the synchronizer's zero-based, host-driven timeline so
        // the frame presents immediately and in order.
        let pts = CMTime(seconds: hostTime - startHostTime, preferredTimescale: 90_000)
        renderAndEnqueue(from: src, itemTime: itemTime, cache: textureCache, pts: pts)
    }

    /// Warp the mono frame into two BGRA eye render targets, convert each to a
    /// 420v buffer (the compositor's native format) via VTPixelTransferSession,
    /// then tag and enqueue. The 420v buffers come from a pool merged with
    /// `recommendedPixelBufferAttributes` — the construction validated on-device.
    /// `CVMutablePixelBuffer` is noncopyable, so the two eye buffers stay local:
    /// borrowed by `transfer`, then consumed by `CVReadOnlyPixelBuffer`.
    private func renderAndEnqueue(from src: CVPixelBuffer, itemTime: CMTime, cache: CVMetalTextureCache, pts: CMTime) {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard width > 0, height > 0,
              ensurePools(width: width, height: height),
              let bgraPool, let outPool,
              let srcTexture = makeTexture(from: src, cache: cache) else { return }

        // 1. Warp into two BGRA eye render targets.
        var leftBGRA: CVPixelBuffer?
        var rightBGRA: CVPixelBuffer?
        let aux: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: maxInFlightBuffers]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, bgraPool, aux as CFDictionary, &leftBGRA) == kCVReturnSuccess,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, bgraPool, aux as CFDictionary, &rightBGRA) == kCVReturnSuccess,
              let leftBGRA, let rightBGRA,
              let leftTex = makeTexture(from: leftBGRA, cache: cache),
              let rightTex = makeTexture(from: rightBGRA, cache: cache),
              let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Depth matched to THIS exact frame: realtime inference blocks until the
        // frame's own depth is ready (slow inference just yields fewer frames);
        // cached mode looks the frame's depth up by presentation time. Either
        // way, image and depth can never mismatch — no ghosting.
        let depthState = signposter.beginInterval("pump-depth")
        let frameDepth = depthSource?.frameDepth(itemTime: itemTime, frame: src)
        signposter.endInterval("pump-depth", depthState)

        var cfg = currentConfig()
        if depthSource?.flattensWhenUnavailable == true {
            // Cached mode: a seek/startup gap renders FLAT (never the heuristic
            // warp, never stale depth), then depth ramps back in to avoid a pop.
            if frameDepth == nil {
                depthResumeTime = nil
                cfg.depthStrength = 0
            } else {
                let now = CACurrentMediaTime()
                let since = depthResumeTime ?? { depthResumeTime = now; return now }()
                cfg.depthStrength *= Float(min(1, (now - since) / depthRampDuration))
            }
        }

        let warpState = signposter.beginInterval("pump-warp")
        encodeEye(into: leftTex, source: srcTexture, depth: frameDepth, eyeSign: 1.0, config: cfg, commandBuffer: cmdBuf)
        encodeEye(into: rightTex, source: srcTexture, depth: frameDepth, eyeSign: -1.0, config: cfg, commandBuffer: cmdBuf)
        cmdBuf.commit()
        // Safe here: this runs on the background pump queue, never main. The warp
        // must complete before VTPixelTransferSession reads the BGRA surfaces.
        cmdBuf.waitUntilCompleted()
        signposter.endInterval("pump-warp", warpState)

        // 2. Convert each BGRA eye → 420v from the recommended-attributes pool,
        // carrying the source's color tags so the compositor reads gamma/range
        // correctly (untagged YCbCr was being misinterpreted = washed out).
        let transferState = signposter.beginInterval("pump-transfer")
        defer { signposter.endInterval("pump-transfer", transferState) }
        guard let left = try? outPool.makeMutablePixelBuffer() else { return }
        guard transfer(from: leftBGRA, to: left) else { return }
        tagColor(left, from: src)
        guard let right = try? outPool.makeMutablePixelBuffer() else { return }
        guard transfer(from: rightBGRA, to: right) else { return }
        tagColor(right, from: src)

        // 3. Tag, describe, enqueue. CVReadOnlyPixelBuffer(_:) consumes each
        // mutable buffer (move), and the format description is built from the
        // tagged group — both exactly as Apple's sample does. (Omitting the
        // format description / using BGRA was a cause of the earlier GPU hang.)
        let presentation = pts.isValid ? pts : .zero
        let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)]
        let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)]
        let tagged: [CMTaggedDynamicBuffer] = [
            CMTaggedDynamicBuffer(tags: leftTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(left))),
            CMTaggedDynamicBuffer(tags: rightTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(right)))
        ]
        let sample = CMReadySampleBuffer(
            taggedBuffers: tagged,
            formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged),
            presentationTimeStamp: presentation,
            duration: CMTime(value: 1, timescale: 90)
        )
        sample.withUnsafeSampleBuffer { videoRenderer.enqueue($0) }
    }

    private func transfer(from source: CVPixelBuffer, to dest: borrowing CVMutablePixelBuffer) -> Bool {
        var ok = false
        dest.withUnsafeBuffer { destBuffer in
            ok = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destBuffer) == noErr
        }
        return ok
    }

    /// Copy the source frame's color primaries / transfer function / YCbCr matrix
    /// onto the eye buffer (defaulting to Rec.709). Without these the compositor
    /// guesses the color space and renders the eyes washed out.
    private func tagColor(_ dest: borrowing CVMutablePixelBuffer, from src: CVPixelBuffer) {
        dest.withUnsafeBuffer { d in
            let primaries = CVBufferGetAttachment(src, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue()
                ?? kCVImageBufferColorPrimaries_ITU_R_709_2
            CVBufferSetAttachment(d, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)

            let transfer = CVBufferGetAttachment(src, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue()
                ?? kCVImageBufferTransferFunction_ITU_R_709_2
            CVBufferSetAttachment(d, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)

            let matrix = CVBufferGetAttachment(src, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue()
                ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2
            CVBufferSetAttachment(d, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    private func encodeEye(
        into dest: MTLTexture,
        source: MTLTexture,
        depth: PumpFrameDepth?,
        eyeSign: Float,
        config: Config,
        commandBuffer: MTLCommandBuffer
    ) {
        // Auto-convergence: keep the (smoothed) median depth on the window
        // plane when the depth source provides one; manual value otherwise.
        let convergence = (config.autoConvergence ? depth?.median : nil) ?? config.convergence
        var uniforms = VideoStereoUniforms(
            brightness: config.brightness,
            contrast: config.contrast,
            saturation: config.saturation,
            depthStrength: config.depthStrength,
            convergence: convergence,
            eyeSign: eyeSign,
            mirror: config.mirror ? 1.0 : 0.0,
            useDepth: depth != nil ? 1.0 : 0.0,
            depthUVScale: depth?.uvScale ?? SIMD2(1, 1),
            depthUVOffset: depth?.uvOffset ?? SIMD2(0, 0),
            depthValueScale: depth?.valueScale ?? 1,
            depthValueBias: depth?.valueBias ?? 0
        )

        // With a real depth map: occlusion-correct depth-displaced mesh. Without
        // one: the per-pixel heuristic warp. Each eye gets its own depth
        // attachment (0=left, 1=right) — the two eyes render in one command
        // buffer, so a shared attachment cross-contaminated the depth test.
        let eyeIndex = eyeSign > 0 ? 0 : 1
        if let depth, let depthAttachment = ensureDepthTexture(width: dest.width, height: dest.height, eye: eyeIndex) {
            let desc = MTLRenderPassDescriptor()
            // MSAA: rasterize into a memoryless multisampled target and resolve
            // into the eye buffer — the mesh's occlusion boundaries are raster
            // edges with no texture-side AA and stairstep without it. The
            // pipeline is built at pseudo3DMSAASampleCount, so the attachments
            // must match; if the transient MSAA target can't be made (never
            // observed — memoryless has no memory backing), skip the frame.
            if renderer.pseudo3DMSAASampleCount > 1 {
                guard let msaaColor = ensureMSAAColorTexture(width: dest.width, height: dest.height, eye: eyeIndex) else { return }
                desc.colorAttachments[0].texture = msaaColor
                desc.colorAttachments[0].resolveTexture = dest
                desc.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                desc.colorAttachments[0].texture = dest
                desc.colorAttachments[0].storeAction = .store
            }
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            desc.depthAttachment.texture = depthAttachment
            desc.depthAttachment.loadAction = .clear
            desc.depthAttachment.clearDepth = 1.0
            desc.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }
            // Grid density per depth source: dense for cached (edge-aware) depth,
            // moderate for realtime — see PumpDepthSource.prefersDenseWarpGrid.
            let dense = depthSource?.prefersDenseWarpGrid == true
            encoder.setRenderPipelineState(renderer.pseudo3DMeshPipelineState)
            encoder.setDepthStencilState(renderer.pseudo3DMeshDepthState)
            encoder.setVertexBuffer(dense ? renderer.pseudo3DDenseGridPositions : renderer.pseudo3DGridPositions, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 1)
            encoder.setVertexTexture(depth.texture, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: dense ? renderer.pseudo3DDenseGridIndexCount : renderer.pseudo3DGridIndexCount,
                indexType: .uint32, indexBuffer: dense ? renderer.pseudo3DDenseGridIndices : renderer.pseudo3DGridIndices, indexBufferOffset: 0
            )
            encoder.endEncoding()
            return
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = dest
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        encoder.setRenderPipelineState(renderer.pseudo3DEyePipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(source, index: 1) // placeholder; unused when useDepth=0
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func ensureDepthTexture(width: Int, height: Int, eye: Int) -> MTLTexture? {
        if let existing = eyeDepthTextures[eye], existing.width == width, existing.height == height {
            return existing
        }
        let texture = renderer.device.makeTexture(descriptor: transientAttachmentDescriptor(
            pixelFormat: .depth32Float, width: width, height: height
        ))
        eyeDepthTextures[eye] = texture
        return texture
    }

    /// Multisampled color target for the MSAA mesh pass (resolved into the eye
    /// buffer). Only called when pseudo3DMSAASampleCount > 1.
    private func ensureMSAAColorTexture(width: Int, height: Int, eye: Int) -> MTLTexture? {
        if let existing = eyeMSAAColorTextures[eye], existing.width == width, existing.height == height {
            return existing
        }
        let texture = renderer.device.makeTexture(descriptor: transientAttachmentDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height
        ))
        eyeMSAAColorTextures[eye] = texture
        return texture
    }

    /// Descriptor for a load-clear/store-discard render attachment: multisampled
    /// at the mesh pipeline's sample count and memoryless (tile memory only —
    /// contents never survive the pass, which is all the mesh pass needs from
    /// its depth buffer and its pre-resolve color).
    private func transientAttachmentDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int) -> MTLTextureDescriptor {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget]
        let samples = renderer.pseudo3DMSAASampleCount
        if samples > 1 {
            desc.textureType = .type2DMultisample
            desc.sampleCount = samples
            desc.storageMode = .memoryless
        } else {
            desc.storageMode = .private
        }
        return desc
    }

    // MARK: GPU helpers

    /// (Re)creates the BGRA warp pool and the 420v output pool for the current
    /// source dimensions. Returns false if either pool can't be made.
    private func ensurePools(width: Int, height: Int) -> Bool {
        if bgraPool != nil, outPool != nil, poolWidth == width, poolHeight == height { return true }

        let bgraAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var bgra: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, bgraAttrs as CFDictionary, &bgra) == kCVReturnSuccess else { return false }

        // 420 output pool, merged with the renderer's recommended attributes —
        // the construction that validated on-device. Full-range (420f, luma
        // 0-255) rather than video-range (420v, 16-235): our warp output is
        // full-range RGB and the compositor reads the tagged buffer as full
        // range, so video-range here lifts blacks / lowers whites (washed out).
        let eyeSize = CVImageSize(width: width, height: height)
        let defaultAttributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            size: eyeSize
        )
        let recommended = videoRenderer.recommendedPixelBufferAttributes
        guard let merged = CVPixelBufferAttributes(merging: [CVPixelBufferAttributes(defaultAttributes), recommended]),
              let creation = CVPixelBufferCreationAttributes(merged),
              let out = try? CVMutablePixelBuffer.Pool(pixelBufferAttributes: creation) else { return false }

        bgraPool = bgra
        outPool = out
        poolWidth = width
        poolHeight = height
        return true
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func reportSizeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard size.width > 0, size.height > 0, lastReportedSize != size else { return }
        lastReportedSize = size
        onVideoSizeKnown(size)
    }
}

// MARK: - StereoTestPatternPump (diagnostic)

/// Feeds the renderer a static stereo test pattern — a bright vertical bar with
/// horizontal disparity over a dark background, so it should appear to float in
/// front of the window when stereo delivery works. Buffer construction mirrors
/// Apple's "Rendering stereoscopic video with RealityKit" sample exactly (420v
/// from a `CVMutablePixelBuffer.Pool` merged with `recommendedPixelBufferAttributes`,
/// `CMTaggedBufferGroupFormatDescription`, pull-model enqueue) to validate the
/// windowed-stereo plumbing without our decode/warp in the loop.
/// `@unchecked Sendable`: all state is touched only on `queue`.
final class StereoTestPatternPump: @unchecked Sendable {
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "com.spatialstash.stereo-testpattern", qos: .userInteractive)
    private let width = 1280
    private let height = 720
    /// Half-frame disparity of the bar between eyes (px). Bigger = more depth.
    private let barShift = 16
    private var pool: CVMutablePixelBuffer.Pool?
    private var frameIndex: Int64 = 0
    private var running = false

    init(videoRenderer: AVSampleBufferVideoRenderer) {
        self.videoRenderer = videoRenderer
    }

    func start() {
        let eyeSize = CVImageSize(width: width, height: height)
        let defaultAttributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            size: eyeSize
        )
        let recommended = videoRenderer.recommendedPixelBufferAttributes
        guard let merged = CVPixelBufferAttributes(merging: [CVPixelBufferAttributes(defaultAttributes), recommended]),
              let creation = CVPixelBufferCreationAttributes(merged),
              let pool = try? CVMutablePixelBuffer.Pool(pixelBufferAttributes: creation) else {
            return
        }
        self.pool = pool
        running = true
        videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.pump()
        }
    }

    func stop() {
        running = false
        videoRenderer.stopRequestingMediaData()
        pool = nil
    }

    private func pump() {
        guard running, let pool else { return }
        while running, videoRenderer.isReadyForMoreMediaData {
            guard enqueueFrame(pool: pool) else { break }
            frameIndex += 1
        }
    }

    private func enqueueFrame(pool: CVMutablePixelBuffer.Pool) -> Bool {
        // Left eye sees the bar shifted right, right eye shifted left → crossed
        // disparity → bar floats in front of the background.
        guard let left = makeEyeBuffer(pool: pool, barShift: barShift),
              let right = makeEyeBuffer(pool: pool, barShift: -barShift) else { return false }
        let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)]
        let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)]
        let tagged: [CMTaggedDynamicBuffer] = [
            CMTaggedDynamicBuffer(tags: leftTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(left))),
            CMTaggedDynamicBuffer(tags: rightTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(right)))
        ]
        let pts = CMTime(value: frameIndex, timescale: 30)
        let sample = CMReadySampleBuffer(
            taggedBuffers: tagged,
            formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged),
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 30)
        )
        sample.withUnsafeSampleBuffer { videoRenderer.enqueue($0) }
        return true
    }

    /// Fills a fresh 420v buffer: dark background (Y=40), a bright vertical bar
    /// (Y=200) centered at `width/2 + barShift`, neutral chroma (grayscale).
    private func makeEyeBuffer(pool: CVMutablePixelBuffer.Pool, barShift: Int) -> CVMutablePixelBuffer? {
        guard let pb = try? pool.makeMutablePixelBuffer() else { return nil }
        pb.withUnsafeBuffer { cv in
            CVPixelBufferLockBaseAddress(cv, [])
            defer { CVPixelBufferUnlockBaseAddress(cv, []) }

            let w = CVPixelBufferGetWidthOfPlane(cv, 0)
            let h = CVPixelBufferGetHeightOfPlane(cv, 0)
            let cx = w / 2 + barShift
            let barHalf = max(8, w / 14)
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(cv, 0) {
                let y = yBase.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(cv, 0)
                for row in 0..<h {
                    let r = y + row * bpr
                    for col in 0..<w {
                        r[col] = abs(col - cx) < barHalf ? 200 : 40
                    }
                }
            }
            // Neutral chroma (Cb=Cr=128) → grayscale.
            if let cBase = CVPixelBufferGetBaseAddressOfPlane(cv, 1) {
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(cv, 1)
                let ch = CVPixelBufferGetHeightOfPlane(cv, 1)
                memset(cBase, 128, bpr * ch)
            }
        }
        return pb
    }
}
