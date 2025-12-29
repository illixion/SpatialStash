# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spatial Stash is a visionOS app for Apple Vision Pro that displays images and videos with 2D to 3D spatial photo conversion. It integrates with [Stash](https://stashapp.cc/) media server via GraphQL API.

## Build Commands

Open `SpatialStash/SpatialStash.xcodeproj` in Xcode. Build and run using:
- **Cmd+B** to build
- **Cmd+R** to run on visionOS Simulator or device

Set your development team in Xcode for bundle identifier configuration (uses `SAMPLE_CODE_DISAMBIGUATOR` from Configuration/SpatialStash.xcconfig).

## Architecture

### App Structure
- **SpatialStashApp.swift** - App entry point, creates main WindowGroup with plain window style
- **AppModel.swift** - Central `@Observable` state container holding navigation, gallery data, server config, and spatial image state

### Data Flow
The app uses two media source types configurable in Settings:
1. **StaticURLImageSource** - Demo mode with hardcoded image URLs
2. **GraphQLImageSource/GraphQLVideoSource** - Fetches from Stash server via `StashAPIClient`

Source protocols:
- `ImageSource` - Protocol for paginated image fetching with optional filter support
- `VideoSource` - Protocol for paginated video fetching

### Tab Navigation
Four tabs defined in `Tab.swift`: Pictures, Videos, Filters, Settings. Tab switching managed by `ContentView` with ornament-based navigation via `TabBarOrnament`.

### Views Hierarchy
- **ContentView** - Root view with tab switching and ornament management
- **PicturesTabView/VideosTabView** - Gallery grids with detail view navigation
- **ImagePresentationView** - RealityKit-based spatial 3D image display
- **FiltersTabView** - Filter configuration for Stash queries (galleries, tags, ratings, o_count)
- **SettingsTabView** - Server URL and API key configuration

### Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated.

### API Client
`StashAPIClient` is an actor that handles GraphQL communication with Stash server. Supports queries for images, videos (scenes), galleries, and tags. Server config persisted via UserDefaults.

## Key Patterns

- MainActor-bound `@Observable` AppModel passed through SwiftUI environment
- Async/await for all network and image generation operations
- Protocol-based data sources for swappable implementations
- UserDefaults for persisting server config and saved filter views
