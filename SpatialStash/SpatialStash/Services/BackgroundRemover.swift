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

        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)

        return applyMaskAndCrop(
            inputImage: originalCIImage,
            maskImage: maskCIImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }

    /// Remove background and produce both regular and auto-enhanced variants.
    /// The foreground mask is generated once from the original image for stable edge
    /// detection. Auto-enhancement is applied to the full original (preserving context
    /// for correct exposure analysis), then the same mask is composited over it.
    /// Returns (regular, autoEnhanced) — either may be nil on failure.
    func removeBackgroundWithAutoEnhance(from image: UIImage) async throws -> (regular: UIImage?, autoEnhanced: UIImage?) {
        guard let cgImage = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for background removal")
            return (nil, nil)
        }

        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)

        // 1. Apply mask to original → regular bg-removed
        let regularResult = applyMaskAndCrop(
            inputImage: originalCIImage,
            maskImage: maskCIImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )

        // 2. Auto-enhance the original CIImage (full-image context for correct analysis)
        let autoFilters = originalCIImage.autoAdjustmentFilters(options: [
            .enhance: true,
            .redEye: false
        ])
        var enhancedCI = originalCIImage
        for filter in autoFilters {
            filter.setValue(enhancedCI, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                enhancedCI = output
            }
        }

        // 3. Apply the same mask to the enhanced version
        let enhancedResult = applyMaskAndCrop(
            inputImage: enhancedCI,
            maskImage: maskCIImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )

        return (regularResult, enhancedResult)
    }

    /// Generate the foreground mask from a CGImage using Vision.
    /// Returns the mask CIImage and the original CIImage.
    private func generateForegroundMask(cgImage: CGImage) throws -> (mask: CIImage, original: CIImage) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        try handler.perform([request])

        guard let result = request.results?.first else {
            AppLogger.backgroundRemover.warning("No foreground mask results")
            throw BackgroundRemovalError.noMaskResults
        }

        let maskPixelBuffer = try result.generateScaledMaskForImage(
            forInstances: result.allInstances,
            from: handler
        )

        return (CIImage(cvPixelBuffer: maskPixelBuffer), CIImage(cgImage: cgImage))
    }

    enum BackgroundRemovalError: Error {
        case noMaskResults
    }

    /// Apply a foreground mask to an image and crop transparent margins.
    private func applyMaskAndCrop(
        inputImage: CIImage,
        maskImage: CIImage,
        scale: CGFloat,
        orientation: UIImage.Orientation
    ) -> UIImage? {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = inputImage
        filter.backgroundImage = CIImage.empty()
        filter.maskImage = maskImage

        guard let outputCIImage = filter.outputImage else {
            AppLogger.backgroundRemover.warning("CIFilter blendWithMask produced no output")
            return nil
        }

        guard let outputCGImage = ciContext.createCGImage(
            outputCIImage,
            from: inputImage.extent
        ) else {
            AppLogger.backgroundRemover.warning("Failed to render CIImage to CGImage")
            return nil
        }

        let processedImage = UIImage(cgImage: outputCGImage, scale: scale, orientation: orientation)

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
