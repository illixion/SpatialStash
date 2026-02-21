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
- **SpatialStashApp.swift** - App entry point defining six scenes: main window, pushed-picture viewer, photo-detail pop-out, shared-photo viewer, shared-video player, and StereoscopicVideoSpace (immersive)
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
Four tabs defined in `Tab.swift`: Pictures, Videos, Filters, Settings. Tab switching managed by `ContentView` with ornament-based navigation via `TabBarOrnament`.

### Photo Viewer Architecture
All three photo viewer windows share the same rendering components:
- **PhotoDisplayView** - Shared image display handling animated GIF, RealityKit 3D, and lightweight 2D UIImage modes. Manages window sizing, swipe navigation, and resize-triggered re-downsampling.
- **PhotoOrnamentView** - Unified ornament bar with `PhotoViewerContext` enum (`.pushedFromGallery`, `.standalone`, `.shared`) controlling which buttons appear.
- **PhotoWindowModel** - Per-window state. Created with `@State` in each wrapper view.

The three thin wrapper views:
- **PushedPictureView** - Pushed from gallery grid via `pushWindow`, dismisses back to gallery. Has pop-out button.
- **PhotoWindowView** - Standalone pop-out window, supports multiple instances. Has gallery button.
- **SharedPhotoWindowView** - Opens for images received via share sheet. Has save button and cache cleanup.

**Important pattern:** `PhotoWindowModel.init` must be side-effect-free because SwiftUI may re-create the view struct multiple times while `@State` discards duplicate models. All side effects (window count tracking, image loading tasks) are deferred to the `start()` method called from `onAppear`.

### Image Display Strategy
- **Default (Dynamic Image Resolution on):** Images open in lightweight 2D mode using a downsampled UIImage via `CGImageSource`. The display image is re-downsampled on window resize (1-second debounce, 20% threshold). RealityKit is only loaded when the user activates 3D mode.
- **Dynamic Image Resolution off:** Images load at full native resolution. No re-downsampling on resize.
- **Auto-3D restoration:** If an image was previously converted to 3D and the user didn't explicitly switch back to 2D, it auto-activates 3D mode on reopen (tracked via `Spatial3DConversionTracker`).

### Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated.

### Video Infrastructure
- **VideoPlayerView** - Standard video playback with ornaments
- **StereoscopicVideoPlayer** - Coordinates download → MV-HEVC conversion → immersive playback
- **MVHEVCConverter** - Converts side-by-side/over-under stereoscopic video to MV-HEVC format
- **ImmersiveVideoView** - RealityKit-based immersive player in full immersion space
- **Video3DSettingsSheet** - Manual override for stereoscopic format detection

### Memory Management
- `useLightweightDisplay` flag triggers all photo windows to switch from RealityKit to SwiftUI Image on memory warning
- `openPhotoWindowCount` tracks active photo windows; `memoryBudgetExceeded` gates new window creation
- `ImageLoader` uses NSCache with 512MB memory limit
- `PhotoWindowModel.cleanup()` explicitly releases GPU textures and image data on window dismiss

### Services
- **StashAPIClient** - Actor for GraphQL communication with Stash server
- **ImageLoader** - Actor-based image loader with NSCache and disk cache
- **DiskImageCache/DiskVideoCache** - Persistent disk caching (excluded from backup)
- **ThumbnailCache** - HEIC-format thumbnail cache
- **ThumbnailGenerator** - Generates thumbnails and performs CGImageSource downsampling
- **SharedMediaCache** - Temporary storage for share sheet media
- **SharedMediaSaver** - Saves shared media to Documents folder
- **Spatial3DConversionTracker** - Tracks which images were converted to 3D and last viewing mode
- **AppLogger** - Structured os.Logger instances across domains

### API Client
`StashAPIClient` is an actor that handles GraphQL communication with Stash server. Supports queries for images, videos (scenes), galleries, and tags. Server config persisted via UserDefaults.

## Key Patterns

- MainActor-bound `@Observable` AppModel passed through SwiftUI environment
- Per-window `@Observable` PhotoWindowModel with side-effect-free init (side effects in `start()`)
- Async/await for all network and image generation operations
- Actor-based concurrency for services (ImageLoader, StashAPIClient, LocalMediaSource, SharedMediaCache)
- Protocol-based data sources (`ImageSource`, `VideoSource`) for swappable implementations
- UserDefaults for persisting server config, saved filter views, and display settings
- Explicit resource cleanup in `cleanup()` methods rather than relying on ARC/deinit

# Stash GraphQL API

You can find the Stash GraphQL API documentation in `internal_docs/Stash_Api_Docs`. **Important:** Claude Code prevents access to this folder while it is in .gitignore, therefore you must temporarily remove it from .gitignore to access the documentation and for your search tool to be able to see it. Undo changes to .gitignore after you are done.
