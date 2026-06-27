# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spatial Stash is a visionOS app for Apple Vision Pro that displays images and videos with 2D to 3D spatial photo conversion. It integrates with [Stash](https://stashapp.cc/) media server via GraphQL API, supports local files, and can receive media via the system share sheet.

## Workflow

Always create a git commit at the end of a task, without waiting for the user to ask. Group related changes into a single commit; keep the commit message focused on the "why".

## Build Commands

Run this command to test your changes:
```bash
xcodebuild -quiet -project SpatialStash/SpatialStash.xcodeproj -scheme SpatialStash -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO
```

## Architecture

### App Structure
- **SpatialStashApp.swift** - App entry point defining scenes: main window, photo-detail pop-out, video-detail, shared-photo viewer, shared-video player, console, GPU memory monitor, remote-viewer, remote-video, remote-alert, and StereoscopicVideoSpace (immersive)
- **AppModel.swift** - Central `@Observable` state container for gallery data, server config, filter state, video playback state, memory monitoring, and persisted settings (UserDefaults)
- **PhotoWindowModel.swift** - Per-window `@Observable` model for individual photo viewers. Contains all stored properties, init/start lifecycle, core image loading pipeline, interaction tracking, shared utilities, and resource cleanup. Split into extension files by concern:
  - **PhotoWindowModel+VisualAdjustments.swift** - Auto-enhance (3-tier cache), brightness/contrast/saturation adjustments, 3D adjustment preview with debounced reload
  - **PhotoWindowModel+Spatial3D.swift** - 3D mode activation/deactivation, `ImagePresentationComponent` creation, spatial 3D generation, viewing mode switching, resolution override
  - **PhotoWindowModel+BackgroundRemoval.swift** - Background removal pipeline: toggle, full-resolution processing, cache loading, resolution reloading, state management
  - **PhotoWindowModel+MemoryManagement.swift** - Idle downscale (release/thumbnail/restore), scene phase tracking, lightweight display transition
  - **PhotoWindowModel+GalleryNavigation.swift** - Gallery image switching, prev/next navigation, lazy loading pagination, rating/O-counter updates
  - **PhotoWindowModel+UIControls.swift** - Share sheet, UI auto-hide timers, image flip

### Data Flow
Three media source types configurable in Settings:
1. **StaticURLImageSource** - Demo mode with hardcoded image URLs
2. **GraphQLImageSource/GraphQLVideoSource** - Fetches from Stash server via `StashAPIClient`
3. **LocalImageSource/LocalVideoSource** - Scans Documents folder for local files

Source protocols:
- `ImageSource` - Protocol for paginated image fetching with optional filter support
- `VideoSource` - Protocol for paginated video fetching

### Tab Navigation
Tabs defined in `Tab.swift`: Pictures, Videos, Local, Filters, Settings, Remote (developer), Console (developer). Tab switching managed by `ContentView` with ornament-based navigation via `TabBarOrnament`. Remote and Console tabs are conditionally visible based on `appModel.enableRemoteViewer` and `appModel.showDebugConsole`.

### Photo Viewer Architecture
All three photo viewer windows share the same rendering components:
- **PhotoDisplayView** - Shared image display with four rendering paths (in priority order): animated GIF (HEVC video player), RealityKit 3D (`ImagePresentationComponent`), GPU-backed 2D (`MetalImageView` with `MTLTexture`), and fallback UIImage. Manages window sizing, swipe navigation, and resize-triggered re-downsampling.
- **PhotoOrnamentView** - Unified ornament bar with `PhotoViewerContext` enum (`.pushedFromGallery`, `.standalone`, `.shared`) controlling which buttons appear. Layout: `[Gallery] | [< N/M >] | [Slideshow] | [3D v] | [Info] | [Share] | [Adjustments] | [extras] | [Resolution]`. The 3D button is a Menu (3D, Immersive 3D, 2D off). The Adjustments button opens `VisualAdjustmentsPopover`, the single home for all image enhancements: brightness/contrast/saturation/sharpen/opacity, auto-enhance, background removal, **and flip**. There is no "More" (triple-dot) menu — context-specific items (Pop Out when pushed, Save when shared) render inline as icon-only buttons via the `extraMenuItems` closure (at most one per context, so a drop-down would be single-item). The Info button opens `MediaDetailSheet` as a sheet.
- **PhotoWindowModel** - Per-window state, split across extension files by concern (see App Structure above). Created with `@State` in each wrapper view. Primary display property is `displayTexture: MTLTexture?` with `displayImage: UIImage?` as fallback. Cached texture variants: `backgroundRemovedTexture`, `originalDisplayTexture`, `autoEnhancedDisplayTexture`, `preAutoEnhanceDisplayTexture`.

The two thin wrapper views:
- **PhotoWindowView** - Handles both pushed and standalone modes via `wasPushed` parameter. Pushed mode: opened via `pushWindow` from gallery, dismisses back to gallery, has pop-out menu item. Standalone mode: opened via `openWindow` as independent pop-out window, has gallery button.
- **SharedPhotoWindowView** - Opens for images received via share sheet. Has save menu item and cache cleanup.

**Important pattern:** `PhotoWindowModel.init` must be side-effect-free because SwiftUI may re-create the view struct multiple times while `@State` discards duplicate models. All side effects (window count tracking, image loading tasks) are deferred to the `start()` method called from `onAppear`.

### Image Display Strategy
- **Default (Dynamic Image Resolution on):** Images open in GPU-backed 2D mode using an `MTLTexture` with `.private` storage (not counted as dirty CPU memory by jetsam). The source is downsampled via `CGImageSource`, uploaded to GPU via `CIContext.render`, and displayed through `MetalImageView` (MTKView wrapper). Re-downsampled on window resize (1-second debounce, 20% threshold). RealityKit is only loaded when the user activates 3D mode.
- **Dynamic Image Resolution off:** Images load at full native resolution. No re-downsampling on resize.
- **Deep color preservation:** Images with >8 bits per component (e.g. 16-bit JXL) use `rgba16Float` textures with `extendedLinearDisplayP3` color space. Standard 8-bit images use `bgra8Unorm` with `deviceRGB`.
- **Auto-3D restore prompt:** If an image was previously viewed in 3D (tracked via `ImageEnhancementTracker`), a capsule prompt pill appears at the bottom of the viewer offering "Restore" or dismiss. Image always opens in 2D — restoration is opt-in. Controlled by `showAutoRestorePrompt` + `autoRestoreImmersive` on `PhotoWindowModel`. Dismisses automatically after 10s (`autoRestorePromptDismissTask`) and when the user navigates to a different image via `switchToImage`. Use `presentAutoRestorePrompt(immersive:)` / `dismissAutoRestorePrompt()` helpers rather than toggling the flag directly so the timer stays in sync.
- **Important:** When swapping `displayTexture` (e.g. toggling background removal or auto-enhance from in-memory cache), `imageAspectRatio` must always be updated from the new texture's dimensions. The Metal renderer stretches the texture to fill its view — aspect ratio is controlled externally by SwiftUI's `.aspectRatio()` modifier driven by `imageAspectRatio`.

### Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated. `ImagePresentationComponent` is a black-box component — it manages its own geometry and materials internally, so there's no direct access to its mesh or rendering pipeline.

**visionOS limitation:** `PostProcessEffect` / `PostProcessEffectContext` are unavailable on visionOS. Custom post-processing on `RealityView` content must use SwiftUI-level modifiers (`.mask()`, `.overlay()`) instead.

### Video Infrastructure
- **VideoWindowModel** - Per-window `@MainActor @Observable` model (mirrors `PhotoWindowModel`) owning the window's current video, navigation snapshot (own copy of `galleryVideos` + `currentIndex` + lazy pagination), 3D intent (`stereoscopicOverride`/`video3DSettings`), flip, per-window `currentAdjustments`, playback state (`currentTime`/`duration`/`isPaused`/`isMuted`/`bufferedEnd`/`isScrubbing`), the `VideoLoopController`, share state, and auto-hide timers. Side-effect-free `init`; side effects in `start()`; `cleanup()` on dismiss. This replaced the old shared `AppModel.selectedVideo`/`videoStereoscopicOverride`/`video3DSettings`/`isVideoFlipped`/`videoVisualAdjustments` + app-level auto-hide, so multiple video windows are fully independent (fixes the bug where every pushed window showed the last-selected video). Created with `@State` in `VideoWindowView(windowValue:appModel:)`.
- **VideoWindowView** - Thin wrapper handling both pushed and standalone modes via `wasPushed` (same pattern as `PhotoWindowView`). Hosts the 2D `WebVideoPlayerView` (or `StereoscopicVideoView`), the `VideoControlBar` overlay, and the ornament. Locks window aspect ratio using **this** window's scene via `@Environment(SceneDelegate.self)` (not an arbitrary foreground scene).
- **VideoControlBar** - Custom SwiftUI transport controls for the 2D web player, replacing Safari's native `<video>` controls. Layout: `[play/pause] [elapsed] [scrubber] [duration] [A-B] [clear?] [mute]`. The scrubber shows the buffered range and A/B loop markers and supports tap-to-seek / drag-to-scrub. Shown only for the 2D player and gated by `!windowModel.isUIHidden` (hides in sync with the ornament; window controls follow ~1.5s later via `persistentSystemOverlays`). Drives the `<video>` entirely through `VideoWindowModel`'s command closures.
- **VideoOrnamentsView** - Unified ornament bar, styled to match `PhotoOrnamentView`. Layout: `[Gallery] | [< N/M >] | [ViewMode v] | [Info] | [Share] | [... More v] | [Title]`. Playback transport (incl. A-B loop) lives in `VideoControlBar`, not here. The More menu contains Adjustments (opens `VisualAdjustmentsPopover`, which hosts the **Flip** toggle), Slideshow, and Pop Out (when pushed). Info button opens `MediaDetailSheet`. Takes `@Bindable var windowModel`.
- **VideoLoopController** - `@Observable @MainActor` per-window model (owned by `VideoWindowModel`) for the A-B loop on the 2D web player. Cycles `idle → aSet → active → idle`: 1st press sets A, **2nd press sets B and engages immediately** (no confirmation step), 3rd press (or the control-bar clear button → `clear()`) disables. Owns its own toast state. Wires `queryCurrentTime`/`setLoopBounds` closures bound by `WebVideoPlayerView` to the JS rVFC monitor (`window.__startABLoop` / `window.__stopABLoop`).
- **WebVideoPlayerView** - `WKWebView`-based player (kept for WebM support). Native `controls` are off for the main video window; a custom-controls bridge is enabled by passing an optional `playbackModel: VideoWindowModel`. State flows JS→Swift over the `videoPlayback` message channel (`timeupdate`/`play`/`pause`/`seeked`/`volumechange`/`loadedmetadata` post `{currentTime,duration,paused,muted,buffered}`); commands flow Swift→JS via `play`/`pause`/`seek`/`setMuted` closures bound in `updateUIView`. The bridge is additive/optional — other callers (animated GIFs in `PhotoDisplayView`, remote-viewer videos, stereoscopic 2D fallback) pass no `playbackModel` and are unaffected.
- **StereoscopicVideoPlayer** - Coordinates download → MV-HEVC conversion → immersive playback. The immersive space is global (one at a time): `StereoscopicVideoView` registers `AppModel.immersiveVideoOwner` (the owning `VideoWindowModel`) on enter, and `ImmersiveVideoView` reads that window's `stereoscopicOverride`.
- **MVHEVCConverter** - Converts side-by-side/over-under stereoscopic video to MV-HEVC format
- **ImmersiveVideoView** - RealityKit-based immersive player in full immersion space
- **Video3DSettingsSheet** - Manual override for stereoscopic format detection

### Memory Management
- **GPU-private textures:** 2D display uses `MTLTexture` with `.private` storage mode. These live in GPU memory (not dirty CPU pages), avoiding jetsam pressure. Apple Silicon applies automatic lossless compression to private textures (~30-50% savings).
- **`SendableTexture` wrapper:** `@unchecked Sendable` struct wrapping `MTLTexture` for crossing actor/Task boundaries, since `MTLTexture` protocol doesn't declare `Sendable`.
- **`DispatchSource` memory pressure:** `AppModel` monitors system memory pressure via `DispatchSource.makeMemoryPressureSource`. On critical pressure, triggers LRU idle-downscale of photo windows. On warning, trims caches.
- **`.mappedIfSafe` data loading:** Disk cache reads use `Data(contentsOf:options:.mappedIfSafe)` for memory-mapped I/O where possible.
- **`autoreleasepool`:** Used around image decode/upload paths to promptly release transient Objective-C objects.
- `useLightweightDisplay` flag triggers all photo windows to switch from RealityKit to SwiftUI Image on memory warning
- `openPhotoWindowCount` tracks active photo windows; `memoryBudgetExceeded` gates new window creation
- `ImageLoader` uses NSCache with 512MB memory limit
- `PhotoWindowModel.cleanup()` explicitly releases GPU textures and image data on window dismiss

### Services
- **MetalImageRenderer** - Sendable singleton managing Metal device, command queue, CIContext, and two render pipeline states (8-bit bgra8Unorm and 16-bit rgba16Float). Creates GPU-private textures from CGImage, UIImage, or URL (with CGImageSource downsampling). Uses `CIContext.render` for correct handling of all source pixel formats and color spaces. Flips CIImage vertically before render (CIImage origin is bottom-left, Metal expects top-left).
- **Shaders.metal** - Vertex shader (procedural fullscreen quad, 6 vertices, no vertex buffer) + fragment shader (brightness/contrast/saturation adjustments matching SwiftUI modifiers).
- **MetalImageView** - `UIViewRepresentable` wrapping `MTKView`. Draw-on-demand mode (`isPaused=true`, `enableSetNeedsDisplay=true`). Transparent background. Auto-detects deep color textures and switches framebuffer format and pipeline state.
- **StashAPIClient** - Actor for GraphQL communication with Stash server
- **ImageLoader** - Actor-based image loader with NSCache and disk cache
- **DiskImageCache/DiskVideoCache** - Persistent disk caching (excluded from backup). Files stored as SHA256 hashes with `.heic` extension.
- **ThumbnailCache** - HEIC-format thumbnail cache
- **ThumbnailGenerator** - Generates thumbnails and performs CGImageSource downsampling
- **BackgroundRemover** - Actor using Vision `VNGenerateForegroundInstanceMaskRequest` + CIFilter blendWithMask for background removal with auto-crop of transparent margins
- **BackgroundRemovalCache** - HEIC-format persistent cache for background-removed images (separate from main disk cache)
- **AutoEnhanceCache** - Persistent cache for auto-enhanced images
- **ImageEnhancementTracker** - Tracks per-image viewing mode (mono/backgroundRemoved/autoEnhanced/spatial3D) for auto-restoration on reopen
- **SharedMediaCache** - Temporary storage for share sheet media
- **SharedMediaSaver** - Saves shared media to Documents folder
- **AppLogger** - Structured os.Logger instances across domains

### API Client
`StashAPIClient` is an actor that handles GraphQL communication with Stash server. Accessible via `appModel.apiClient` (private(set)). Supports:
- **List queries:** `findImages`, `findScenes`, `findGalleries`, `findTags`, `findStudios`, `findPerformers` (paginated, with filters)
- **Detail queries:** `fetchImageDetail(id:)` → `ImageDetail`, `fetchSceneDetail(id:)` → `SceneDetail` (on-demand full metadata)
- **Mutations:** `updateImage`/`updateScene` (full field update), `updateImageRating`/`updateSceneRating`, `incrementImageOCounter`/`decrementImageOCounter`, `incrementSceneOCounter`/`decrementSceneOCounter`
- **Delete:** `destroyImage`/`destroyScene` (single), `destroyImages`/`destroyScenes` (bulk), with `deleteFile` and `deleteGenerated` options
- Server config persisted via UserDefaults

### Media Metadata & Detail Views
- **MediaMetadata.swift** - Lightweight shared structs: `MediaTag`, `MediaPerformer`, `MediaStudio`, `MediaGalleryRef`, `MediaGroupRef`, plus full detail structs `ImageDetail` and `SceneDetail` (fetched on-demand, not in list queries)
- **MediaDetailSheet** - Two-tab sheet (Info read-only + Edit) opened from the ornament Info button. Info tab shows file metadata, associations (tags/performers/studio/galleries as chips via `FlowLayout`), and stats. Edit tab has searchable pickers for tags/performers/studio, text fields, rating editor, URL list, and organized toggle. **Edits are committed automatically when the sheet closes** (both the "Done" button and swipe/other dismissal via `onDisappear`) — there is no explicit Save button; `commitChanges(using:)` writes only when `hasUnsavedChanges` (diffed against an `EditSnapshot` baseline). O-counter +/- is committed immediately (separate from the save-on-close path). On a successful save the `onSaved(rating100)` callback lets the presenting ornament update `windowModel.image`/`video.rating100` so the Info icon refreshes live. Delete section at bottom with confirmation dialog ("Remove from Stash" vs "Delete File from Disk")

### Multi-Select
Gallery grids (`GalleryGridView`, `VideoGalleryView`) support multi-select mode:
- Toolbar "Select" button toggles `appModel.isSelectingImages`/`isSelectingVideos`
- Thumbnails show checkbox overlay; tapping toggles selection in `selectedImageIds`/`selectedVideoIds` (Set<String> of stash IDs)
- Bottom selection toolbar: Select All / Deselect All, count label, Delete button with bulk confirmation dialog
- Bulk delete via `destroyImages`/`destroyScenes` API calls

### Remote API Viewer
A slideshow viewer that fetches images from a [RoboFrame](https://github.com/illixion/RoboFrame) API and displays them with clock/sensor overlays, Ken Burns animation, WebSocket control, and Home Assistant integration. Enabled via Settings → Developer → Enable Remote API Viewer, which adds a "Remote" tab.

**Protocol reference:** The authoritative WebSocket protocol spec lives in the RoboFrame repo at `~/Projects/RoboFrame/docs/protocol.md` (frames, readiness barrier, playback cycle, action scoping). Consult it before changing any WS message handling.

**Architecture:**
- **RemoteViewerConfig** — Codable config struct with all settings, saved to UserDefaults via AppModel
- **SlideshowEngine** — `@MainActor @Observable` reusable base class running a state machine (idle → loading → displaying ⇄ paused / backgrounded → stopped). Owns prefetch buffer (3 images ahead), crossfade transitions, Sobel-based Ken Burns focus, dynamic brightness, scene-phase handling, and navigation. Content is preserved across background cycles — the engine has no aggressive unload timer and relies on normal image cycling to bound memory.
- **RemoteViewerModel** — `SlideshowEngine` subclass adding WS integration, save/block, sensor display, Display Sync, and config persistence. Also used as the app's slideshow engine (replaces the old PhotoWindowModel slideshow; gallery mode uses `GalleryContentProvider` as the content source)
- **SlideshowContentProvider** / **RemoteContentProvider** / **GalleryContentProvider** — protocol + implementations that abstract post fetching and image downloading so the engine is agnostic to the source
- **RemoteViewerWindowView** — Main viewer window with image/clock/sensor layers, ornament with auto-hide. Supports both remote API and gallery image sources
- **RemoteAPIClient** — Actor for search/get/save/history HTTP endpoints
- **RemoteWebSocketClient** — `@Observable` class managing a single `URLSessionWebSocketTask` with auto-reconnect. Not owned by a single viewer — acquired from `SlideshowSyncHub`.
- **SlideshowSyncHub** — `@MainActor` singleton providing (1) WS connection pooling keyed by endpoint URL so multiple viewer windows share one connection (RoboFrame server messages broadcast to every subscriber), and (2) local Display Sync broadcast between in-process `RemoteViewerModel` instances (current/next image, prefetched queue, cached posts, cursor, delay — `UIImage` is reference-typed so no bitmap copies)
- **SobelFocusAnalyzer** — Pure functions for Sobel edge detection (Ken Burns focus) and average luminance (dynamic brightness)

**RoboFrame Proxy API:**
- `GET {baseURL}/get?id={postId}` → serves image directly (used as img src)
- `GET {baseURL}/save?id={postId}` → saves post, returns status text
- `GET {baseURL}/addtohistory?id={postId}` → adds to viewing history
- There is no `/search` endpoint — the RoboFrame server is the single DuckDB reader. Posts arrive via the WebSocket `playback` channel.

**WebSocket Protocol (JSON, `{ action, payload }`):**
- **Outgoing:** `slideshowConfig {sessionId, deviceId, interval, width, height, bright, convert, lowmem, ratio?}` (sent on connect), `visibility {deviceId, visible}`, `block {id}`, `displaySync {sessionId, enabled}` (claim/release primary), `setModTags {sessionId, tags}`, `requestNext {sessionId}`, `setTagList {sessionId, listNumber}` (per-channel — only the sender's deviceId switches list)
- **Incoming:** `tagLists [[String]]` (server-pushed catalog), `playback {primary, enabled, interval, currentList, modTags, current: {id, ext}, next: {id, ext}}` (active list index lives in `currentList`; there is no standalone `currentTagList` frame any more), `playVideo {url}`, `stopVideo`, `showText {text, bgColorHex, imageUrl}`, `dismissText`, `update {entity, state, attributes}` (HA sensors), `refresh`
- `playVideo`/`showText` open new windows via `openWindow()`; `stopVideo`/`dismissText` dismiss them

**Key implementation details:**
- The server is authoritative on tag list, mod tags, current/next post, and channel timing. Clients render whatever `playback` says and preload the announced `next` via `/get`.
- **No client-side advance in remote mode.** The engine is purely server-driven (`serverDriven` flag set in `start()`): it has no local dwell clock and only ever transitions to a server-pushed `current` (via `setServerCurrent` → `reconcileWithServer`). Advancing locally races the orchestrator and surfaces a prefetched post that ignores the window's advertised ratio (e.g. a wide image in a tall window with fit-to-aspect on). So: **Block** just sends `block` (server drops the post and broadcasts a fresh ratio-appropriate `current`); the **Next button** emits `requestNext` (`advanceToNext()`, the protocol's per-channel advance) rather than `goToNextImage`; the **refresh** frame clears caches and calls `reconcileWithServer` (reload, not advance). `goToNextImage` is gallery-mode only. The exceptions are **Prev** and **history-jump**, which replay already-seen posts or are explicit manual overrides. Never implement a wake-advance (requesting next on returning from background) — the server already owns dwell timing; see protocol.md "no client-side wake-advance".
- Ratio filter uses `..` separator (e.g. `ratio:1.32..1.79`), matching server expectations
- Blocked posts/tags from WS `blocked` are merged into local config and persisted
- Save button has 1.5s grace period after image transition (saves previous post)
- Visual adjustments (brightness/contrast/saturation) stack: auto (luminance-based) + per-viewer + global
- Ornament: [ Grid | Prev | Next | Save | Home | Cycle Tags | Display Sync | Adjustments | Block ] (Save/Home/Cycle/Display Sync/Block hidden in gallery mode)
- Adjustments popover has a "Viewer" tab with display toggles (clock, sensors, Ken Burns, background, aspect ratio)
- Images are downsampled on load using `maxImageResolution` from app settings via `CGImageSourceCreateThumbnailAtIndex`
- **Gallery mode:** When `apiEndpoint` is empty, the viewer pulls from `appModel.imageSource` instead of the remote API. The photo viewer's slideshow button launches a gallery-mode viewer window. API-only features (WS, save, block, history, tag cycling) are disabled
- **Background handling:** On background the engine transitions to `.backgrounded` (pausing the run loop) and remembers `stateBeforeBackground`. Content (current/next image, prefetch queue, cached posts) is preserved — on return to active the engine resumes with the same image. WS visibility reporting is immediate. Previously the engine had a 30s unload timer but it was removed — the recovery path from nil content was fragile and the normal cycle already bounds memory.
- **Display Sync:** When the toggle is on, `onPostTransitioned` both sends the WS `displaySync` message (RoboFrame server coordination) and calls `SlideshowSyncHub.broadcastLocalSync` to mirror current/next image, prefetched queue, cached posts, cursor, and delay to every other registered local instance via `RemoteViewerModel.applyLocalDisplaySync`. An `isApplyingIncomingSync` flag suppresses rebroadcast during the crossfade await to prevent feedback loops. Pause/play state is intentionally not mirrored. Shared `TagListManager` already propagates tag list switches across windows so those don't need to ride the sync payload.
- **Shared WS:** All `RemoteViewerModel`s with the same `wsEndpoint` share a single `RemoteWebSocketClient` obtained via `SlideshowSyncHub.subscribeWS`. Each subscriber passes its own `deviceId` to `sendVisibilityChange(deviceId:visible:)`. Server messages (RoboFrame broadcasts for all device IDs by design) fan out to every subscriber; the connection closes when the last subscriber leaves.

## Key Patterns

- MainActor-bound `@Observable` AppModel passed through SwiftUI environment
- Per-window `@Observable` PhotoWindowModel with side-effect-free init (side effects in `start()`)
- Async/await for all network and image generation operations
- Actor-based concurrency for services (ImageLoader, StashAPIClient, LocalMediaSource, SharedMediaCache)
- Protocol-based data sources (`ImageSource`, `VideoSource`) for swappable implementations
- UserDefaults for persisting server config, saved filter views, and display settings
- Explicit resource cleanup in `cleanup()` methods rather than relying on ARC/deinit
- The Xcode project's files are automatically managed, therefore there is no need to update project files when adding new source files. Just create the new .swift file in the appropriate folder and it will be included in the build.

# Stash GraphQL API

You can find the Stash GraphQL API documentation in `internal_docs/Stash_Api_Docs`. **Important:** Claude Code prevents access to this folder while it is in .gitignore, therefore you must temporarily remove it from .gitignore to access the documentation and for your search tool to be able to see it. Undo changes to .gitignore after you are done.
