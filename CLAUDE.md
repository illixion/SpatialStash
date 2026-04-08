# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spatial Stash is a visionOS app for Apple Vision Pro that displays images and videos with 2D to 3D spatial photo conversion. It integrates with [Stash](https://stashapp.cc/) media server via GraphQL API, supports local files, and can receive media via the system share sheet.

## Build Commands

Run this command to test your changes:
```bash
xcodebuild -quiet -project SpatialStash/SpatialStash.xcodeproj -scheme SpatialStash -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

## Architecture

### App Structure
- **SpatialStashApp.swift** - App entry point defining scenes: main window, photo-detail pop-out, video-detail, shared-photo viewer, shared-video player, console, GPU memory monitor, remote-viewer, remote-video, remote-alert, and StereoscopicVideoSpace (immersive)
- **AppModel.swift** - Central `@Observable` state container for gallery data, server config, filter state, video playback state, memory monitoring, and persisted settings (UserDefaults)
- **PhotoWindowModel.swift** - Per-window `@Observable` model for individual photo viewers. Manages image loading, 2D/3D display mode, gallery navigation, slideshow, and resource cleanup. All three photo viewer windows use this model.

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
- **PhotoOrnamentView** - Unified ornament bar with `PhotoViewerContext` enum (`.pushedFromGallery`, `.standalone`, `.shared`) controlling which buttons appear.
- **PhotoWindowModel** - Per-window state. Created with `@State` in each wrapper view. Primary display property is `displayTexture: MTLTexture?` with `displayImage: UIImage?` as fallback. Cached texture variants: `backgroundRemovedTexture`, `originalDisplayTexture`, `autoEnhancedDisplayTexture`, `preAutoEnhanceDisplayTexture`.

The three thin wrapper views:
- **PushedPictureView** - Pushed from gallery grid via `pushWindow`, dismisses back to gallery. Has pop-out button.
- **PhotoWindowView** - Standalone pop-out window, supports multiple instances. Has gallery button.
- **SharedPhotoWindowView** - Opens for images received via share sheet. Has save button and cache cleanup.

**Important pattern:** `PhotoWindowModel.init` must be side-effect-free because SwiftUI may re-create the view struct multiple times while `@State` discards duplicate models. All side effects (window count tracking, image loading tasks) are deferred to the `start()` method called from `onAppear`.

### Image Display Strategy
- **Default (Dynamic Image Resolution on):** Images open in GPU-backed 2D mode using an `MTLTexture` with `.private` storage (not counted as dirty CPU memory by jetsam). The source is downsampled via `CGImageSource`, uploaded to GPU via `CIContext.render`, and displayed through `MetalImageView` (MTKView wrapper). Re-downsampled on window resize (1-second debounce, 20% threshold). RealityKit is only loaded when the user activates 3D mode.
- **Dynamic Image Resolution off:** Images load at full native resolution. No re-downsampling on resize.
- **Deep color preservation:** Images with >8 bits per component (e.g. 16-bit JXL) use `rgba16Float` textures with `extendedLinearDisplayP3` color space. Standard 8-bit images use `bgra8Unorm` with `deviceRGB`.
- **Auto-3D restoration:** If an image was previously converted to 3D and the user didn't explicitly switch back to 2D, it auto-activates 3D mode on reopen (tracked via `Spatial3DConversionTracker`).
- **Important:** When swapping `displayTexture` (e.g. toggling background removal or auto-enhance from in-memory cache), `imageAspectRatio` must always be updated from the new texture's dimensions. The Metal renderer stretches the texture to fill its view — aspect ratio is controlled externally by SwiftUI's `.aspectRatio()` modifier driven by `imageAspectRatio`.

### Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated. `ImagePresentationComponent` is a black-box component — it manages its own geometry and materials internally, so there's no direct access to its mesh or rendering pipeline.

**visionOS limitation:** `PostProcessEffect` / `PostProcessEffectContext` are unavailable on visionOS. Custom post-processing on `RealityView` content must use SwiftUI-level modifiers (`.mask()`, `.overlay()`) instead.

### Video Infrastructure
- **VideoPlayerView** - Standard video playback with ornaments
- **StereoscopicVideoPlayer** - Coordinates download → MV-HEVC conversion → immersive playback
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
`StashAPIClient` is an actor that handles GraphQL communication with Stash server. Supports queries for images, videos (scenes), galleries, and tags. Server config persisted via UserDefaults.

### Remote API Viewer
A slideshow viewer that fetches images from a [RoboFrame](https://github.com/illixion/RoboFrame) API and displays them with clock/sensor overlays, Ken Burns animation, WebSocket control, and Home Assistant integration. Enabled via Settings → Developer → Enable Remote API Viewer, which adds a "Remote" tab.

**Architecture:**
- **RemoteViewerConfig** — Codable config struct with all settings, saved to UserDefaults via AppModel
- **RemoteViewerModel** — `@MainActor @Observable` slideshow engine. Manages prefetch buffer (3 images ahead), crossfade transitions, Sobel-based Ken Burns focus, dynamic brightness, WS integration, client-side block filtering, and gallery mode. Also used as the app's slideshow engine (replaces the old PhotoWindowModel slideshow)
- **RemoteViewerWindowView** — Main viewer window with image/clock/sensor layers, ornament with auto-hide. Supports both remote API and gallery image sources
- **RemoteAPIClient** — Actor for search/get/save/history HTTP endpoints
- **RemoteWebSocketClient** — `@Observable` class managing URLSessionWebSocketTask with reconnection
- **SobelFocusAnalyzer** — Pure functions for Sobel edge detection (Ken Burns focus) and average luminance (dynamic brightness)

**RoboFrame Proxy API:**
- `GET {baseURL}/search?q={tags}&cursor={cursor}` → `{ results: [RemotePost], nextCursor: number }`
- `GET {baseURL}/get?id={postId}` → serves image directly (used as img src)
- `GET {baseURL}/save?id={postId}` → saves post, returns status text
- `GET {baseURL}/addtohistory?id={postId}` → adds to viewing history
- URL is built manually (not via URLQueryItem) to avoid over-encoding `>=` in tag queries

**WebSocket Protocol (JSON, `{ action, payload }`):**
- **Outgoing:** `getBlocked`, `getDisplayState`, `block {postId}`, `displaySync {currentPost, nextPost, currentList, dbCursor}`
- **Incoming:** `blocked {blockedPosts, blockedTags}`, `displayState {state}`, `currentTagList {listNumber}`, `playVideo {url}`, `stopVideo`, `showText {text, bgColorHex, imageUrl}`, `dismissText`, `update {entity, state, attributes}` (HA sensors), `refresh`, `displaySync`
- `playVideo`/`showText` open new windows via `openWindow()`; `stopVideo`/`dismissText` dismiss them

**Key implementation details:**
- Cursor is randomized on initial load (`Double.random(in: 0..<1)`) and re-randomized when server returns `nextCursor: 0` (wrap-around)
- Ratio filter uses `..` separator (e.g. `ratio:1.32..1.79`), matching server expectations
- Blocked posts/tags from WS `getBlocked` are merged into local config and persisted
- Save button has 1.5s grace period after image transition (saves previous post)
- Visual adjustments (brightness/contrast/saturation) stack: auto (luminance-based) + per-viewer + global
- Ornament: [ Grid | Prev | Next | Save | Home | Cycle Tags | Adjustments | Block ] (Save/Home/Cycle/Block hidden in gallery mode)
- Adjustments popover has a "Viewer" tab with display toggles (clock, sensors, Ken Burns, background, aspect ratio)
- Images are downsampled on load using `maxImageResolution` from app settings via `CGImageSourceCreateThumbnailAtIndex`
- **Gallery mode:** When `apiEndpoint` is empty, the viewer pulls from `appModel.imageSource` instead of the remote API. The photo viewer's slideshow button launches a gallery-mode viewer window. API-only features (WS, save, block, history, tag cycling) are disabled
- **Background handling:** On background, slideshow pauses and images are held for 30s then unloaded. On return to active: if <30s, resumes with previous image; if ≥30s, advances to next image. WS visibility reporting is immediate and unaffected by the timer

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
