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

/// Matches `ImageUniforms` in Shaders.metal
private struct ImageUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
}

struct MetalImageView: UIViewRepresentable {
    let texture: MTLTexture?
    let brightness: Float
    let contrast: Float
    let saturation: Float

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

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Redraw when drawable size changes — ensures the image is rendered
            // at the correct resolution after layout (especially on first appear
            // when the view may initially have zero size).
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let renderer,
                  let texture,
                  let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                return
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }

            // Select pipeline matching the framebuffer format
            let pipeline = (view.colorPixelFormat == .rgba16Float)
                ? renderer.pipelineState16
                : renderer.pipelineState

            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)

            var uniforms = ImageUniforms(brightness: brightness, contrast: contrast, saturation: saturation)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImageUniforms>.size, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
