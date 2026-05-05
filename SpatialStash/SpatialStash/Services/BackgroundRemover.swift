/*
 Spatial Stash - Background Remover

 Uses the Vision framework's VNGenerateForegroundInstanceMaskRequest
 to detect foreground subjects and CoreImage to composite the result
 with a transparent background.
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import os
import UIKit
import Vision

actor BackgroundRemover {
    static let shared = BackgroundRemover()

    /// Cap on the long edge (in pixels) of the image fed into Vision.
    /// Vision's segmentation model resamples internally to ~512–1024px regardless of input,
    /// so feeding a 33MP source just multiplies pre/post-processing and composite cost
    /// without improving silhouette quality. 2560 keeps mask edges crisp at panel-resolution
    /// viewing while cutting work ~10-16x on 8K sources.
    private static let maxLongEdgeForSegmentation: CGFloat = 2560

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {}

    /// Remove the background from a UIImage and return the foreground at the
    /// source's original frame size (no transparent-margin cropping). Used by
    /// diorama mode where the foreground must align with the unmodified
    /// backdrop via z-offset layering.
    func removeBackgroundUncropped(from image: UIImage) async throws -> UIImage? {
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for uncropped background removal")
            return nil
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)

        let filter = CIFilter.blendWithMask()
        filter.inputImage = originalCIImage
        filter.backgroundImage = CIImage.empty()
        filter.maskImage = maskCIImage

        guard let outputCIImage = filter.outputImage,
              let outputCGImage = ciContext.createCGImage(outputCIImage, from: originalCIImage.extent) else {
            return nil
        }
        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Remove the background from a UIImage, automatically cropping transparent space.
    /// Returns a new UIImage with transparent background and no fully transparent margins.
    func removeBackground(from image: UIImage) async throws -> UIImage? {
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for background removal")
            return nil
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
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
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for background removal")
            return (nil, nil)
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
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

    /// Downsample a CGImage so its long edge does not exceed `maxLongEdgeForSegmentation`.
    /// Returns the original image if it's already within the cap.
    /// Uses `CGContext` resampling for predictable quality and to avoid the ImageIO
    /// thumbnail path (which requires a CGImageSource and we only have a CGImage here).
    private static func downsampleIfNeeded(_ image: CGImage) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longEdge = max(w, h)
        guard longEdge > maxLongEdgeForSegmentation else { return image }

        let scale = maxLongEdgeForSegmentation / longEdge
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())

        return CGImageDeepColor.redraw(image, size: (newW, newH)) ?? image
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

        let croppedCGImage = TransparentEdgeCropper.crop(outputCGImage)
        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: orientation)
    }
}
