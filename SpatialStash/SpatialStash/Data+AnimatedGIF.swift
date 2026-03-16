/*
 Spatial Stash - Data Animated GIF Detection

 Helper to detect if image data contains an animated GIF by checking
 the frame count via CGImageSource.
 */

import ImageIO
import Foundation

extension Data {
    var isAnimatedGIF: Bool {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 1
    }
}
