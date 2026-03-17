/*
 Spatial Stash - Visual Adjustments

 Non-destructive visual adjustment settings (brightness, contrast, saturation)
 applied via SwiftUI view modifiers or CSS filters. Stored per-image via
 ImageEnhancementTracker and as global defaults via AppModel/UserDefaults.
 */

import Foundation

struct VisualAdjustments: Codable, Equatable {
    /// SwiftUI .brightness() range: typically -0.5 to 0.5, where 0.0 = no change
    var brightness: Double = 0.0

    /// SwiftUI .contrast() range: 0.0 to 3.0, where 1.0 = no change
    var contrast: Double = 1.0

    /// SwiftUI .saturation() range: 0.0 to 3.0, where 1.0 = no change
    var saturation: Double = 1.0

    /// Whether CIImage auto-enhancement filters have been applied (photos only)
    var isAutoEnhanced: Bool = false

    /// Whether any adjustment differs from the neutral defaults
    var isModified: Bool {
        brightness != 0.0 || contrast != 1.0 || saturation != 1.0 || isAutoEnhanced
    }

    /// Reset all values to their neutral defaults
    mutating func reset() {
        brightness = 0.0
        contrast = 1.0
        saturation = 1.0
        isAutoEnhanced = false
    }

    /// CSS filter string for WebVideoPlayerView (GIF/video via WKWebView).
    /// CSS brightness(1.0) = no change; SwiftUI brightness 0.0 = no change.
    /// Conversion: CSS brightness = 1.0 + SwiftUI brightness.
    /// Contrast and saturation use the same scale in both systems.
    var cssFilterString: String {
        let cssBrightness = 1.0 + brightness
        return "brightness(\(cssBrightness)) contrast(\(contrast)) saturate(\(saturation))"
    }
}
