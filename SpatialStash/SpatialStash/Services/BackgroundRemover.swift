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
        try await generateDioramaPair(from: image).foreground
    }

    /// Generate the foreground + a subject-removed backdrop in a single Vision
    /// pass. The backdrop replaces the subject region with a heavily blurred
    /// version of the original so the diorama overlay doesn't show a doubled
    /// silhouette behind the floating foreground when viewed off-axis. The
    /// non-subject regions stay sharp at full resolution.
    func generateDioramaPair(from image: UIImage) async throws -> (foreground: UIImage?, backdrop: UIImage?) {
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for diorama pair")
            return (nil, nil)
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)
        let extent = originalCIImage.extent

        // Foreground: original masked by subject alpha, full-frame, transparent bg.
        let fgFilter = CIFilter.blendWithMask()
        fgFilter.inputImage = originalCIImage
        fgFilter.backgroundImage = CIImage.empty()
        fgFilter.maskImage = maskCIImage

        let foregroundImage: UIImage? = {
            guard let outputCIImage = fgFilter.outputImage,
                  let outputCGImage = ciContext.createCGImage(outputCIImage, from: extent) else {
                return nil
            }
            return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
        }()

        // Backdrop: heavy gaussian blur of the original, composited under the
        // original via the mask so only the subject region is blurred.
        // Radius is scaled by image size — about 2.5% of the long edge gives
        // a strong "out of focus" smear without leaking detail through.
        let blurRadius = max(20.0, Double(max(extent.width, extent.height)) * 0.025)
        let clamped = originalCIImage.clampedToExtent()
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clamped
        blurFilter.radius = Float(blurRadius)
        let blurred = blurFilter.outputImage?.cropped(to: extent) ?? originalCIImage

        // Backdrop mask: dilate the foreground mask significantly so the blur
        // region extends beyond the actual silhouette. This covers two cases
        // the foreground mask alone misses: (a) interior holes from
        // probabilistic Vision output (the "swiss cheese" effect — through
        // those holes the unblurred original would leak the subject), and
        // (b) edge feathering, where the silhouette band would otherwise
        // show a sharp original/blurred boundary right at the foreground.
        let dilateRadius = max(8.0, Double(max(extent.width, extent.height)) * 0.015)
        let backdropDilate = CIFilter.morphologyMaximum()
        backdropDilate.inputImage = maskCIImage
        backdropDilate.radius = Float(dilateRadius)
        let backdropMask = backdropDilate.outputImage?.cropped(to: extent) ?? maskCIImage

        // blendWithMask: where mask is opaque (subject), show inputImage (blurred);
        // where mask is transparent (background), show backgroundImage (original).
        let bgFilter = CIFilter.blendWithMask()
        bgFilter.inputImage = blurred
        bgFilter.backgroundImage = originalCIImage
        bgFilter.maskImage = backdropMask

        let backdropImage: UIImage? = {
            guard let outputCIImage = bgFilter.outputImage,
                  let outputCGImage = ciContext.createCGImage(outputCIImage, from: extent) else {
                return nil
            }
            return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
        }()

        return (foregroundImage, backdropImage)
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

        let rawMask = CIImage(cvPixelBuffer: maskPixelBuffer)
        return (Self.refineMask(rawMask), CIImage(cgImage: cgImage))
    }

    /// Clean up Vision's soft probabilistic mask before compositing.
    ///
    /// Vision's `VNGenerateForegroundInstanceMaskRequest` returns a grayscale
    /// mask where interior pixels often carry alpha around 0.3–0.7 in regions
    /// the model is uncertain about. That manifests as the "cloud-like"
    /// translucency you can see when compositing — particularly noticeable on
    /// digital art and stylized images where Vision's training distribution
    /// doesn't match the input.
    ///
    /// Two-step refinement:
    ///  1. Morphological closing (dilate → erode) fills small interior holes
    ///     while leaving the silhouette dimensions roughly intact.
    ///  2. Contrast steepening pushes interior pixels to ~1 and background
    ///     pixels to ~0, leaving only a thin soft band at the silhouette
    ///     boundary — the matting equivalent of Pixelmator Pro's first-stage
    ///     mask cleanup before its color-decontamination pass.
    private static func refineMask(_ mask: CIImage) -> CIImage {
        let extent = mask.extent

        // Closing radius needs to be big enough to fill the medium-sized
        // interior holes Vision returns on stylized inputs. 10px in mask
        // space closes ~20px-diameter holes — large enough to bridge typical
        // probabilistic gaps without erasing legitimate features (e.g.
        // between fingers).
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = mask
        dilate.radius = 10
        guard let dilated = dilate.outputImage else { return mask }

        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = dilated
        erode.radius = 10
        guard let closed = erode.outputImage?.cropped(to: extent) else { return mask }

        // Contrast steepening with a bias toward keeping soft pixels as
        // foreground. Vision's interior fog often sits in the 0.3–0.45 band;
        // a symmetric curve around 0.5 would push those to background and
        // create the "swiss cheese" hole pattern. brightness=+0.2 shifts the
        // effective midpoint to ~0.3, so anything Vision was at-least-somewhat
        // confident about (>~0.3) snaps to opaque while clear-background
        // (<~0.3) snaps to transparent.
        let contrast = CIFilter.colorControls()
        contrast.inputImage = closed
        contrast.contrast = 10.0
        contrast.brightness = 0.2
        contrast.saturation = 1.0
        guard let contrasted = contrast.outputImage?.cropped(to: extent) else { return closed }

        // Clamp to [0, 1]. CI's working color space is extended-linear, so the
        // contrast pump produces interior values >>1 and background values <0.
        // blendWithMask reads these literally as `out = mask*fg + (1-mask)*bg`,
        // which over-amplifies the foreground when a mask value of 8 is
        // multiplied through the RGB. Clamp resolves it.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = contrasted
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage?.cropped(to: extent) ?? contrasted
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
