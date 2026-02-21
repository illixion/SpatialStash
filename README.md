# Spatial Stash

A visionOS app for Apple Vision Pro that transforms your 2D images into immersive 3D spatial photos. Browse your media library from a [Stash](https://github.com/stashapp/stash) server, local files, or use the built-in demo mode.

## Features

- **2D to 3D Conversion** - Uses Apple's RealityKit to convert standard images into spatial 3D photos viewable on Vision Pro, with automatic restoration of 3D state for previously converted images
- **Stash Server Integration** - Connect to your Stash media server via GraphQL API to browse images and videos
- **Local Files** - Browse images and videos from the app's Documents folder
- **Share Sheet Support** - Receive images and videos from other apps via the system share sheet, with save-to-files option
- **Advanced Filtering** - Filter by galleries, tags, ratings, performers and more with saved filter presets
- **Swipe Navigation** - Swipe between images in the gallery with smooth transitions
- **Slideshow** - Random image slideshow with configurable delay
- **Rating & O-Count** - View and edit image ratings and O-count directly from the viewer
- **Video Playback** - Stream videos directly from your Stash server or play local files
- **Stereoscopic 3D Video** - Automatically detects SBS/OU stereoscopic formats from tags, converts to MV-HEVC, and plays in full immersive mode
- **Unlimited Windows** - Open multiple image viewer windows that persist in your space
- **Memory Management** - Lightweight 2D display by default with automatic downsampling, configurable dynamic image resolution, and memory-aware window management
- **Demo Mode** - Try the app with bundled sample images without server setup

## Screenshots

![Home](images/home.jpeg)
![Viewer](images/viewer.jpeg)
![Filters](images/filters.jpeg)
![Settings](images/settings.jpeg)

## Requirements

- Apple Vision Pro or visionOS Simulator
- Xcode 15.0+
- visionOS 26.0+
- (Optional) [Stash](https://github.com/stashapp/stash) server for media library integration

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/illixion/spatialstash.git
   cd spatialstash
   ```

2. Open the project in Xcode:
   ```bash
   open SpatialStash/SpatialStash.xcodeproj
   ```

3. Select your development team in Xcode (Project → Signing & Capabilities)

4. Build and run on visionOS Simulator or device (Cmd+R)

## Configuration

### Demo Mode
The app starts in demo mode with sample images. No configuration required.

### Stash Server
To connect to your Stash server:

1. Open the app and navigate to the **Settings** tab
2. Change **Media Source** to "Stash Server"
3. Enter your Stash server URL (e.g., `http://192.168.1.100:9999`)
4. Enter your API key if authentication is enabled
5. Tap **Apply & Test Connection**

### Local Files
To use local files:

1. Change **Media Source** to "Local Files"
2. Place images in the app's Documents/Photos/ folder and videos in Documents/Videos/
3. Tap **Refresh All Content** to scan for new files

## Usage

### Pictures Tab
Browse your image gallery in a grid view. Tap any image to open it in the viewer:
- **Swipe** left/right to navigate between images
- Tap the **wand** button to generate a spatial 3D version
- Tap the **play** button to start a random slideshow
- Tap the **star** button to view/edit rating and O-count (Stash server only)
- Tap the **pop-out** button to open the image in its own window
- Images that were previously viewed in 3D will automatically restore to 3D mode
- The window automatically adjusts to match image aspect ratios

### Videos Tab
Browse and play videos. Stereoscopic 3D videos are automatically detected from Stash tags and can be played in full immersive mode after conversion to MV-HEVC format.

### Filters Tab
Create complex queries to filter your media (Stash server only):
- Search by title
- Filter by galleries, performers, studios, tags
- Filter by rating (1-5 stars) or O-count
- Sort by date, title, rating, or random
- Save filter combinations as presets for quick access or as default views

### Settings Tab
- **Media Source** - Switch between Demo, Stash Server, and Local Files
- **Dynamic Image Resolution** - Toggle automatic image downsampling based on window size (on by default, turn off for full-resolution display)
- **Auto-hide Controls** - Configure how long ornament controls stay visible
- **Slideshow Delay** - Set the interval between slideshow images
- **Stash Server** - Configure server URL and API key
- **Cache Management** - View and clear image/video disk caches

## Architecture

The app follows a SwiftUI architecture with:
- `AppModel` - Central `@Observable` state container for app-wide state
- `PhotoWindowModel` - Per-window `@Observable` model for photo viewers, managing image loading, 2D/3D display, navigation, and slideshow
- `PhotoDisplayView` + `PhotoOrnamentView` - Shared components used by all three photo viewer windows
- Protocol-based data sources (`ImageSource`, `VideoSource`) for swappable implementations
- `StashAPIClient` actor for thread-safe GraphQL communication
- RealityKit integration via `ImagePresentationComponent` for spatial photos
- `StereoscopicVideoPlayer` + `MVHEVCConverter` for stereoscopic 3D video conversion and immersive playback

## License

See [LICENSE.txt](LICENSE.txt) for licensing information.

## Acknowledgments

- [Stash](https://github.com/stashapp/stash) - Self-hosted media organizer
- Built with Apple's RealityKit and SwiftUI frameworks
