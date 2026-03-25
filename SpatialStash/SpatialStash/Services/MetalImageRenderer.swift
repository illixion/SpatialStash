/*
 Spatial Stash - Metal Image Renderer

 Singleton service managing Metal device, command queue, render pipeline,
 and texture creation. Uploads CGImage/UIImage data to GPU-private
 MTLTexture objects so decoded pixels live in GPU memory (not dirty CPU
 pages), reducing jetsam pressure.

 Uses CIContext to render images into Metal textures, which handles all
 source pixel formats, color spaces, and bit depths correctly.
 Preserves 16-bit per channel color depth when the source image provides it.
 */

import CoreImage
import Metal
import MetalKit
import ImageIO
import UIKit

/// Sendable wrapper for MTLTexture. Metal texture objects are thread-safe GPU
/// resource handles, but the protocol doesn't declare Sendable conformance.
struct SendableTexture: @unchecked Sendable {
    let texture: MTLTexture
}

/// Manages Metal resources for GPU-backed image display.
/// All texture creation is nonisolated and thread-safe through Metal's own guarantees.
final class MetalImageRenderer: Sendable {
    static let shared = MetalImageRenderer()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let pipelineState16: MTLRenderPipelineState
    private let ciContext: CIContext

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .outputPremultiplied: true
        ])

        // Build render pipeline for fullscreen quad + brightness/contrast/saturation shader
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "imageVertexShader"),
              let fragmentFunction = library.makeFunction(name: "imageFragmentShader") else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction

        // Enable alpha blending for images with transparency (background removal)
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            // 8-bit pipeline (bgra8Unorm framebuffer)
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

            // 16-bit pipeline (rgba16Float framebuffer for HDR / deep color)
            pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            self.pipelineState16 = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            return nil
        }
    }

    // MARK: - Texture Creation

    /// Create a GPU-private texture from a CGImage.
    /// Uses CIContext to render into a Metal texture, correctly handling all
    /// source pixel formats, color spaces, and bit depths.
    func createTexture(from cgImage: CGImage, useLossyCompression: Bool = false) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let isDeepColor = cgImage.bitsPerComponent > 8
        let pixelFormat: MTLPixelFormat = isDeepColor ? .rgba16Float : .bgra8Unorm

        // Create a writable staging texture for CIContext to render into.
        // CIContext.render requires .shaderWrite, which is incompatible with
        // lossy compression, so we always render to an uncompressed texture first.
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        stagingDesc.usage = [.shaderRead, .shaderWrite]
        stagingDesc.storageMode = .private

        guard let stagingTexture = device.makeTexture(descriptor: stagingDesc),
              let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        // CIImage origin is bottom-left; Metal textures expect top-left.
        // Flip vertically so the rendered image isn't upside down.
        let ciImage = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height)))

        // Render the CIImage directly into the private Metal texture.
        // CIContext handles all color space conversion and pixel format normalization.
        let colorSpace = isDeepColor
            ? (CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpaceCreateDeviceRGB()

        ciContext.render(
            ciImage,
            to: stagingTexture,
            commandBuffer: cmdBuf,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )

        if useLossyCompression {
            // Blit-copy from the uncompressed staging texture into a lossy-compressed
            // read-only texture. The staging texture is released after the copy completes.
            let lossyDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            lossyDesc.usage = [.shaderRead]
            lossyDesc.storageMode = .private
            lossyDesc.compressionType = .lossy

            guard let lossyTexture = device.makeTexture(descriptor: lossyDesc),
                  let blit = cmdBuf.makeBlitCommandEncoder() else {
                // Fall back to returning the uncompressed staging texture
                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
                return stagingTexture
            }

            blit.copy(
                from: stagingTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: lossyTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            return lossyTexture
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return stagingTexture
    }

    /// Create a GPU-private texture from a UIImage.
    func createTexture(from uiImage: UIImage, useLossyCompression: Bool = false) -> MTLTexture? {
        guard let cgImage = uiImage.cgImage else { return nil }
        return createTexture(from: cgImage, useLossyCompression: useLossyCompression)
    }

    /// Downsample an image from a URL and upload directly to a GPU-private texture.
    /// Uses CGImageSource for memory-efficient decoding without loading the full image.
    func createTexture(from url: URL, maxDimension: CGFloat, useLossyCompression: Bool = false) -> MTLTexture? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }

            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource, 0, options as CFDictionary
            ) else {
                return nil
            }

            return createTexture(from: cgImage, useLossyCompression: useLossyCompression)
        }
    }
}
