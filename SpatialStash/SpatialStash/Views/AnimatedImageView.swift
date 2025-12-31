/*
 Spatial Stash - Animated Image View

 UIViewRepresentable wrapper that displays animated GIFs using UIImageView.
 Falls back to standard display for non-animated images.
 */

import SwiftUI
import UIKit

/// A SwiftUI wrapper for UIImageView that supports animated GIF display
struct AnimatedImageView: UIViewRepresentable {
    let imageData: Data
    let contentMode: UIView.ContentMode

    init(data: Data, contentMode: UIView.ContentMode = .scaleAspectFill) {
        self.imageData = data
        self.contentMode = contentMode
    }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Check if this is an animated GIF by looking for multiple frames
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil) {
            let frameCount = CGImageSourceGetCount(source)

            if frameCount > 1 {
                // This is an animated GIF - create animated UIImage
                var images: [UIImage] = []
                var totalDuration: Double = 0

                for i in 0..<frameCount {
                    if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) {
                        images.append(UIImage(cgImage: cgImage))

                        // Get frame duration
                        if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                           let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                            if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double, delayTime > 0 {
                                totalDuration += delayTime
                            } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime] as? Double {
                                totalDuration += delayTime
                            } else {
                                totalDuration += 0.1 // Default 100ms per frame
                            }
                        } else {
                            totalDuration += 0.1
                        }
                    }
                }

                if !images.isEmpty {
                    uiView.animationImages = images
                    uiView.animationDuration = totalDuration
                    uiView.animationRepeatCount = 0 // Loop forever
                    uiView.image = images.first
                    uiView.startAnimating()
                    return
                }
            }
        }

        // Not an animated GIF - display as static image
        uiView.animationImages = nil
        uiView.stopAnimating()
        uiView.image = UIImage(data: imageData)
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: ()) {
        uiView.stopAnimating()
        uiView.animationImages = nil
        uiView.image = nil
    }
}

/// Helper to detect if image data is an animated GIF
extension Data {
    var isAnimatedGIF: Bool {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 1
    }
}
