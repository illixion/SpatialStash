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

    /// Color decontamination kernel. At each silhouette-band pixel (where
    /// alpha is in (0,1)), inverts the matte equation observed = α·F + (1-α)·B
    /// to recover the contaminant-free foreground color. Without this, soft-
    /// alpha pixels carry the original background color (e.g. white halo
    /// around black ink lines on a white page) and render incorrectly when
    /// composited onto a new backdrop. CIColorKernel runs per-pixel with no
    /// neighbor sampling — the background estimate is supplied as a
    /// precomputed heavy blur of the source.
    ///
    /// FIXME: the CI-Kernel-Language `init(source:)` is deprecated in favor
    /// of Metal-based CIKernels. Migrating requires adding a `.ci.metal`
    /// file with custom build settings, which this project hasn't set up.
    /// Functional on visionOS; revisit if Apple removes the GL path.
    private static let decontaminationKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 decontaminate(__sample input, __sample mask, __sample bg) {
            float a = mask.r;
            if (a < 0.001) {
                return vec4(0.0, 0.0, 0.0, 0.0);
            }
            if (a > 0.999) {
                return vec4(input.rgb, 1.0);
            }
            vec3 clean = (input.rgb - (1.0 - a) * bg.rgb) / a;
            return vec4(clamp(clean, 0.0, 1.0), a);
        }
    """)

    /// Mask firming kernel. Vision returns medium-confidence (0.3–0.6) alpha
    /// across the subject interior on stylized digital art — too transparent
    /// for the diorama foreground to composite opaquely against the blurred
    /// backdrop (the blur shows through the foreground at 40-70%). A linear
    /// CIColorControls curve can't fix this without cropping everything
    /// below 0.4 (the previous "stairstep" thin-feature loss). Smoothstep
    /// has the right shape: hard ceiling at the high end, hard floor at the
    /// low end, cubic interpolation between for clean silhouette transitions.
    ///
    /// Edges (0.05, 0.4): values ≥ 0.4 → fully opaque (subject interior
    /// firms up regardless of Vision's confidence), values ≤ 0.05 → fully
    /// transparent (clean background, no haze), values in between get a
    /// smooth cubic ramp that preserves silhouette anti-aliasing and keeps
    /// thin features (typically α ∈ 0.15–0.35) visible at proportional alpha.
    private static let maskFirmingKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 firmMask(__sample mask) {
            float a = smoothstep(0.05, 0.4, mask.r);
            return vec4(vec3(a), 1.0);
        }
    """)

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

        // Heavy gaussian blur of the original — used both as the diorama
        // backdrop's blurred subject region AND as the bg estimate for
        // foreground color decontamination. Radius scales with image size.
        let blurRadius = max(20.0, Double(max(extent.width, extent.height)) * 0.025)
        let clamped = originalCIImage.clampedToExtent()
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clamped
        blurFilter.radius = Float(blurRadius)
        let blurred = blurFilter.outputImage?.cropped(to: extent) ?? originalCIImage

        // Foreground: decontaminated color + mask alpha. Replaces the prior
        // blendWithMask path so silhouette pixels carry clean subject color
        // (no halo from the original background bleeding through soft alpha).
        let foregroundImage: UIImage? = {
            guard let kernel = Self.decontaminationKernel,
                  let outputCIImage = kernel.apply(extent: extent, arguments: [originalCIImage, maskCIImage, blurred]),
                  let outputCGImage = ciContext.createCGImage(outputCIImage, from: extent) else {
                return nil
            }
            return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
        }()

        // Backdrop mask: small dilation just to ensure the silhouette band
        // is fully blurred (without it, the soft transition pixels would show
        // sharp original on one side and blurred on the other right at the
        // silhouette — visible as a thin sharp edge). Now that the foreground
        // mask has its interior holes filled, we don't need aggressive
        // dilation to cover leakage; a few pixels suffices and keeps the
        // blur edge tight to the subject instead of casting a shadow.
        let dilateRadius: Double = 5
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

        // Decontamination kernel bakes the mask alpha into its output, so
        // we render+crop directly. Fall back to blendWithMask only if the
        // kernel failed to compile.
        if let decontaminated = decontaminatedRGBA(input: originalCIImage, mask: maskCIImage) {
            return renderAndCrop(decontaminated, extent: originalCIImage.extent, scale: image.scale, orientation: image.imageOrientation)
        }
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
        let extent = originalCIImage.extent

        // 1. Regular variant — decontaminated + mask alpha baked in.
        let regularResult: UIImage? = {
            if let decontaminated = decontaminatedRGBA(input: originalCIImage, mask: maskCIImage) {
                return renderAndCrop(decontaminated, extent: extent, scale: image.scale, orientation: image.imageOrientation)
            }
            return applyMaskAndCrop(
                inputImage: originalCIImage,
                maskImage: maskCIImage,
                scale: image.scale,
                orientation: image.imageOrientation
            )
        }()

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

        // 3. Enhanced variant — decontaminate using post-enhance colors so the
        // bg estimate matches the pixels we're un-mixing against.
        let enhancedResult: UIImage? = {
            if let decontaminated = decontaminatedRGBA(input: enhancedCI, mask: maskCIImage) {
                return renderAndCrop(decontaminated, extent: extent, scale: image.scale, orientation: image.imageOrientation)
            }
            return applyMaskAndCrop(
                inputImage: enhancedCI,
                maskImage: maskCIImage,
                scale: image.scale,
                orientation: image.imageOrientation
            )
        }()

        return (regularResult, enhancedResult)
    }

    /// Render a CIImage that already carries final alpha (from the
    /// decontamination kernel) to a CGImage, then trim transparent margins.
    /// Distinct from `applyMaskAndCrop` which would re-multiply by the mask.
    private func renderAndCrop(_ image: CIImage, extent: CGRect, scale: CGFloat, orientation: UIImage.Orientation) -> UIImage? {
        guard let outputCGImage = ciContext.createCGImage(image, from: extent) else { return nil }
        let cropped = TransparentEdgeCropper.crop(outputCGImage)
        return UIImage(cgImage: cropped, scale: scale, orientation: orientation)
    }

    /// Apply color decontamination to `input` using `mask`. Computes a heavy
    /// gaussian blur of `input` as the bg estimate and runs the kernel.
    /// Returns nil if the kernel isn't available or extent is empty.
    private func decontaminatedRGBA(input: CIImage, mask: CIImage) -> CIImage? {
        let extent = input.extent
        guard extent.width > 0, extent.height > 0,
              let kernel = Self.decontaminationKernel else { return nil }

        let blurRadius = max(20.0, Double(max(extent.width, extent.height)) * 0.025)
        let clamped = input.clampedToExtent()
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clamped
        blurFilter.radius = Float(blurRadius)
        let bgEstimate = blurFilter.outputImage?.cropped(to: extent) ?? input

        return kernel.apply(extent: extent, arguments: [input, mask, bgEstimate])
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
        return (refineMask(rawMask), CIImage(cgImage: cgImage))
    }

    /// Clean up Vision's soft probabilistic mask before compositing.
    ///
    /// Pipeline:
    ///  1. Morphological closing fills small holes left by Vision's
    ///     probabilistic interior output.
    ///  2. **Smoothstep firming** (`maskFirmingKernel`) pushes Vision's
    ///     medium-confidence interior pixels (0.4+) to fully opaque while
    ///     preserving silhouette anti-aliasing and thin features below 0.4.
    ///     Replaces the prior `CIColorControls` linear curve, which couldn't
    ///     simultaneously firm up 0.5-input-to-opaque AND keep thin
    ///     features intact — the linear shape has wrong slope for this.
    ///  3. **Flood-fill enclosed holes** — anything not reachable from the
    ///     image boundary via background pixels gets forced to opaque,
    ///     fixing large interior cavities morphology can't close.
    private func refineMask(_ mask: CIImage) -> CIImage {
        let extent = mask.extent

        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = mask
        dilate.radius = 10
        guard let dilated = dilate.outputImage else { return mask }

        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = dilated
        erode.radius = 10
        guard let closed = erode.outputImage?.cropped(to: extent) else { return mask }

        // Smoothstep firming. Output already in [0,1] (smoothstep saturates).
        let firmed: CIImage
        if let kernel = Self.maskFirmingKernel,
           let firmedOutput = kernel.apply(extent: extent, arguments: [closed]) {
            firmed = firmedOutput
        } else {
            firmed = closed
        }

        return fillEnclosedHoles(firmed) ?? firmed
    }

    /// Fill mask regions that aren't reachable from the image boundary via
    /// background pixels. CPU pass — converts the mask to an 8-bit grayscale
    /// buffer, flood-fills from the four edges marking everything reachable
    /// through pixels below threshold, then forces any unmarked sub-threshold
    /// pixel to opaque (interior hole). Preserves the silhouette band's soft
    /// alpha by only modifying pixels that were already binarized to
    /// background by the contrast step.
    ///
    /// Cost: O(width × height) once per image. ~3.7M pixels at 2560×1440.
    /// Stack-based iterative flood fill to avoid recursion depth issues.
    private func fillEnclosedHoles(_ mask: CIImage) -> CIImage? {
        let extent = mask.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // Render to a single-channel 8-bit buffer via CIContext. Going through
        // a CGContext + draw(CGImage) path doesn't work for this — the mask
        // CIImage from `cvPixelBuffer:` doesn't have an addressable CGImage
        // until rendered. CIContext.render writes directly to a bitmap.
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let graySpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            ciContext.render(
                mask,
                toBitmap: base,
                rowBytes: bytesPerRow,
                bounds: extent,
                format: .L8,
                colorSpace: graySpace
            )
        }

        // Background threshold matches the contrast step's effective cutoff.
        // After clamp, interior pixels are at 255 and background at 0; the
        // soft silhouette band is in between. We treat anything < 128 as
        // background-candidate for flood-fill purposes — silhouette pixels
        // above 128 are subject and won't be visited.
        let threshold: UInt8 = 128
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        stack.reserveCapacity(max(width, height) * 2)

        // Seed with all four image edges.
        for x in 0..<width {
            if pixels[x] < threshold { stack.append(x) }
            let bottomIdx = (height - 1) * width + x
            if pixels[bottomIdx] < threshold { stack.append(bottomIdx) }
        }
        for y in 1..<(height - 1) {
            let leftIdx = y * width
            if pixels[leftIdx] < threshold { stack.append(leftIdx) }
            let rightIdx = leftIdx + width - 1
            if pixels[rightIdx] < threshold { stack.append(rightIdx) }
        }

        // 4-connectivity flood fill. Marks every background pixel reachable
        // from the boundary; anything left unmarked is by definition enclosed.
        while let idx = stack.popLast() {
            if visited[idx] { continue }
            visited[idx] = true
            let x = idx % width
            let y = idx / width
            if x > 0 {
                let n = idx - 1
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
            if x < width - 1 {
                let n = idx + 1
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
            if y > 0 {
                let n = idx - width
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
            if y < height - 1 {
                let n = idx + width
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
        }

        // Fill: any sub-threshold pixel not visited is an enclosed hole.
        // Set to fully opaque so blendWithMask treats it as subject.
        for i in 0..<pixels.count {
            if !visited[i] && pixels[i] < threshold {
                pixels[i] = 255
            }
        }

        // Reconstruct CIImage from the modified pixel buffer.
        guard let outCtx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let outCG = outCtx.makeImage() else {
            return nil
        }
        let filled = CIImage(cgImage: outCG)
        // Translate to match the original mask's extent origin (rare to be
        // non-zero, but mask buffers from Vision can be).
        return filled.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
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
