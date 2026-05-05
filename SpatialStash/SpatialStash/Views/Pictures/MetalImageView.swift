/*
 Spatial Stash - Metal Image View

 UIViewRepresentable wrapping MTKView for displaying GPU-private
 MTLTexture objects in SwiftUI. Draws on demand (not 60fps) and
 applies brightness/contrast/saturation via Metal fragment shader.
 Supports both 8-bit (bgra8Unorm) and 16-bit (rgba16Unorm / rgba16Float)
 source textures.
 */

import MetalKit
import SwiftUI

/// Matches `ImageUniforms` in Shaders.metal — pass-1 (RCAS) input.
private struct ImageUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var sharpen: Float
}

/// Matches `AAUniforms` in Shaders.metal — pass-2 (resolve + tonal) input.
private struct AAUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var applyResolve: Float
}

struct MetalImageView: UIViewRepresentable {
    let texture: MTLTexture?
    let brightness: Float
    let contrast: Float
    let saturation: Float
    let sharpen: Float

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        guard let renderer = MetalImageRenderer.shared else {
            return MTKView()
        }

        let mtkView = MTKView(frame: .zero, device: renderer.device)
        mtkView.delegate = context.coordinator

        // Draw on demand, not continuously
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        // Transparent background so SwiftUI background shows through
        mtkView.isOpaque = false
        mtkView.layer.isOpaque = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // Pick framebuffer format based on texture depth
        let is16Bit = texture.map { Self.isDeepColor($0) } ?? false
        mtkView.colorPixelFormat = is16Bit ? .rgba16Float : .bgra8Unorm

        // Store current state in coordinator
        context.coordinator.renderer = renderer
        context.coordinator.texture = texture
        context.coordinator.brightness = brightness
        context.coordinator.contrast = contrast
        context.coordinator.saturation = saturation
        context.coordinator.sharpen = sharpen

        mtkView.setNeedsDisplay()
        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        let coordinator = context.coordinator
        var needsRedraw = false

        if coordinator.texture !== texture {
            // Switch framebuffer format if bit depth changed
            let is16Bit = texture.map { Self.isDeepColor($0) } ?? false
            let requiredFormat: MTLPixelFormat = is16Bit ? .rgba16Float : .bgra8Unorm
            if mtkView.colorPixelFormat != requiredFormat {
                mtkView.colorPixelFormat = requiredFormat
            }
            coordinator.texture = texture
            needsRedraw = true
        }
        if coordinator.brightness != brightness {
            coordinator.brightness = brightness
            needsRedraw = true
        }
        if coordinator.contrast != contrast {
            coordinator.contrast = contrast
            needsRedraw = true
        }
        if coordinator.saturation != saturation {
            coordinator.saturation = saturation
            needsRedraw = true
        }
        if coordinator.sharpen != sharpen {
            coordinator.sharpen = sharpen
            needsRedraw = true
        }

        if needsRedraw {
            mtkView.setNeedsDisplay()
        }
    }

    /// Check if a texture uses a deep color (>8-bit) pixel format.
    private static func isDeepColor(_ texture: MTLTexture) -> Bool {
        switch texture.pixelFormat {
        case .rgba16Unorm, .rgba16Float, .rgba16Snorm,
             .rgba32Float, .rg16Float, .r16Float:
            return true
        default:
            return false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: MetalImageRenderer?
        var texture: MTLTexture?
        var brightness: Float = 0
        var contrast: Float = 1
        var saturation: Float = 1
        var sharpen: Float = 0

        /// Offscreen RCAS target. Allocated lazily and reused across draws.
        /// Reallocated when drawable size or pixel format changes.
        private var intermediate: MTLTexture?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Drawable resize — drop the cached intermediate so it gets
            // reallocated at the new size on the next draw.
            intermediate = nil
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let renderer,
                  let texture,
                  let drawable = view.currentDrawable,
                  let finalPassDesc = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                return
            }

            let is16 = view.colorPixelFormat == .rgba16Float
            let useRCAS = sharpen > 0.001
            let drawableW = drawable.texture.width
            let drawableH = drawable.texture.height

            // Pass-2 input texture: either the offscreen RCAS result, or the source.
            var pass2InputTexture: MTLTexture = texture

            if useRCAS {
                // Render RCAS at source resolution for SSAA — capped at 2×
                // drawable per axis so a huge source doesn't blow up VRAM.
                // Floor at drawable size so we never upsample-then-downsample
                // a small source for no benefit.
                let interW = min(max(texture.width, drawableW), drawableW * 2)
                let interH = min(max(texture.height, drawableH), drawableH * 2)

                let intermediateTex = ensureIntermediate(
                    device: renderer.device,
                    width: interW,
                    height: interH,
                    pixelFormat: view.colorPixelFormat
                )

                if let intermediateTex {
                    let pass1Desc = MTLRenderPassDescriptor()
                    pass1Desc.colorAttachments[0].texture = intermediateTex
                    pass1Desc.colorAttachments[0].loadAction = .clear
                    pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    pass1Desc.colorAttachments[0].storeAction = .store

                    if let pass1Encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) {
                        let rcasPipeline = is16 ? renderer.rcasPipelineState16 : renderer.rcasPipelineState
                        pass1Encoder.setRenderPipelineState(rcasPipeline)
                        pass1Encoder.setFragmentTexture(texture, index: 0)
                        var rcasU = ImageUniforms(brightness: 0, contrast: 1, saturation: 1, sharpen: sharpen)
                        pass1Encoder.setFragmentBytes(&rcasU, length: MemoryLayout<ImageUniforms>.size, index: 0)
                        pass1Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                        pass1Encoder.endEncoding()
                        pass2InputTexture = intermediateTex
                    }
                }
            }

            // Engage rotated-grid resolve whenever pass-2's input is larger
            // than the drawable — independent of RCAS. A raw source bigger
            // than the drawable still benefits from area-averaged downsample
            // (existing aliasing in the source gets smoothed out).
            let didSupersample = pass2InputTexture.width > drawableW || pass2InputTexture.height > drawableH

            guard let pass2Encoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPassDesc) else {
                return
            }

            let finalPipeline = is16 ? renderer.pipelineState16 : renderer.pipelineState
            pass2Encoder.setRenderPipelineState(finalPipeline)
            pass2Encoder.setFragmentTexture(pass2InputTexture, index: 0)

            var aaU = AAUniforms(
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                applyResolve: didSupersample ? 1.0 : 0.0
            )
            pass2Encoder.setFragmentBytes(&aaU, length: MemoryLayout<AAUniforms>.size, index: 0)
            pass2Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            pass2Encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Allocate or reuse the offscreen RCAS target. Returns nil on failure.
        private func ensureIntermediate(
            device: MTLDevice,
            width: Int,
            height: Int,
            pixelFormat: MTLPixelFormat
        ) -> MTLTexture? {
            if let existing = intermediate,
               existing.width == width,
               existing.height == height,
               existing.pixelFormat == pixelFormat {
                return existing
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            let tex = device.makeTexture(descriptor: desc)
            intermediate = tex
            return tex
        }
    }
}
