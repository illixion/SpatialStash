/*
 Spatial Stash - Background Remover

 Uses the Vision framework's VNGenerateForegroundInstanceMaskRequest
 to detect foreground subjects and CoreImage to composite the result
 with a transparent background.
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import os
import UIKit
import Vision

actor BackgroundRemover {
    static let shared = BackgroundRemover()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {}

    /// Remove the background from a UIImage, automatically cropping transparent space.
    /// Returns a new UIImage with transparent background and no fully transparent margins.
    func removeBackground(from image: UIImage) async throws -> UIImage? {
        guard let cgImage = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for background removal")
            return nil
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        try handler.perform([request])

        guard let result = request.results?.first else {
            AppLogger.backgroundRemover.warning("No foreground mask results")
            return nil
        }

        let maskPixelBuffer = try result.generateScaledMaskForImage(
            forInstances: result.allInstances,
            from: handler
        )

        let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)
        let originalCIImage = CIImage(cgImage: cgImage)

        let filter = CIFilter.blendWithMask()
        filter.inputImage = originalCIImage
        filter.backgroundImage = CIImage.empty()
        filter.maskImage = maskCIImage

        guard let outputCIImage = filter.outputImage else {
            AppLogger.backgroundRemover.warning("CIFilter blendWithMask produced no output")
            return nil
        }

        guard let outputCGImage = ciContext.createCGImage(
            outputCIImage,
            from: originalCIImage.extent
        ) else {
            AppLogger.backgroundRemover.warning("Failed to render CIImage to CGImage")
            return nil
        }

        let processedImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)

        // Auto-crop to remove fully transparent margins
        if let croppedImage = cropTransparentSpace(from: processedImage) {
            return croppedImage
        }

        return processedImage
    }

    /// Crop all fully transparent alpha channel space from an image's edges.
    /// Returns nil if the entire image is transparent or if cropping fails.
    private func cropTransparentSpace(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4 // RGBA

        guard let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data as Data? else {
            AppLogger.backgroundRemover.warning("Unable to access pixel data for cropping")
            return nil
        }

        // Find bounds of non-transparent pixels
        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                guard pixelIndex + 3 < pixelData.count else {
                    AppLogger.backgroundRemover.warning("Pixel index out of bounds during crop calculation")
                    return nil
                }

                let alpha = pixelData[pixelIndex + 3]
                if alpha > 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        // Check if entire image is transparent
        guard minX <= maxX && minY <= maxY else {
            AppLogger.backgroundRemover.warning("Image is entirely transparent, cannot crop")
            return nil
        }

        let croppingRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )

        guard let croppedCGImage = cgImage.cropping(to: croppingRect) else {
            AppLogger.backgroundRemover.warning("Failed to crop CGImage")
            return nil
        }

        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
