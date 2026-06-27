# Stereoscopic Rendering on visionOS: Live Metal Textures Without MV-HEVC

A reference for feeding live-generated per-eye Metal textures to the visionOS compositor as true stereoscopic content.

---

## TL;DR

| Goal | Requires ImmersiveSpace? | Public API |
|------|--------------------------|------------|
| Stereo in a shared-space window | No | `VideoPlayerComponent(videoRenderer:)` + tagged `CMSampleBuffer` |
| True low-latency, full-immersion render loop | Yes | `CompositorServices.LayerRenderer` |
| Decode existing side-by-side/MV-HEVC file frames | Either | `AVPlayerItemVideoOutput` + `VTPixelTransferSession` |

---

## Path A — Shared Window: RealityKit + AVSampleBufferVideoRenderer

Apple's own sample ("Rendering stereoscopic video with RealityKit") demonstrates this path in the **Shared Space**. No ImmersiveSpace required, no MV-HEVC encoding, no file I/O. The trick is building a `CMReadySampleBuffer` that carries two tagged pixel buffers—one per eye—and enqueuing it to `AVSampleBufferVideoRenderer`, which is wired up to a `VideoPlayerComponent`.

### 1. Setup

```swift
import AVFoundation
import RealityKit

// One renderer per window; cannot be shared between VideoPlayerComponents.
let videoRenderer = AVSampleBufferVideoRenderer()
let synchronizer = AVSampleBufferRenderSynchronizer()
synchronizer.addRenderer(videoRenderer)

// Build the RealityKit entity.
var playerComponent = VideoPlayerComponent(videoRenderer: videoRenderer)
// Ask for stereo if the content supports it.
playerComponent.desiredViewingMode = .stereo
let videoEntity = Entity()
videoEntity.components.set(playerComponent)
```

Add `videoEntity` to your `RealityView` content. The system compositor will route the left-eye buffer to the left display and vice-versa automatically.

### 2. Create IOSurface-backed CVPixelBuffers for Metal

Metal textures must be backed by an IOSurface so the compositor can import them without a CPU round-trip. Use `AVSampleBufferVideoRenderer.recommendedPixelBufferAttributes` to match the renderer's internal format expectations.

```swift
import CoreVideo
import Metal

func makeEyePixelBufferPool(
    renderer: AVSampleBufferVideoRenderer,
    width: Int,
    height: Int
) -> CVPixelBufferPool {
    let base = CVPixelBufferCreationAttributes(
        pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        size: CVImageSize(width: width, height: height),
        ioSurfaceProperties: [:]   // forces IOSurface backing
    )
    let recommended = renderer.recommendedPixelBufferAttributes
    guard let merged = CVPixelBufferAttributes(merging: [CVPixelBufferAttributes(base), recommended]),
          let creation = CVPixelBufferCreationAttributes(merged),
          let pool = try? CVMutablePixelBuffer.Pool(pixelBufferAttributes: creation)
    else { fatalError("Failed to create pixel buffer pool") }
    return pool
}
```

> **Why IOSurface?** IOSurface-backed buffers can be imported into Metal as `MTLTexture`s via `CVMetalTextureCache` with zero copy. The compositor also reads them without a CPU blit.

### 3. Bridge Metal Textures ↔ CVPixelBuffer via CVMetalTextureCache

```swift
var textureCache: CVMetalTextureCache?
CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, MTLCreateSystemDefaultDevice()!, nil, &textureCache)

/// Returns an MTLTexture view into the IOSurface-backed pixel buffer's luma plane.
func metalTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
    let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    var cvTexture: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache,
        pixelBuffer, nil,
        .r8Unorm,   // luma plane; use .rg8Unorm for the chroma plane
        w, h, 0,
        &cvTexture
    )
    return cvTexture.flatMap(CVMetalTextureGetTexture)
}
```

Render your frame into the `MTLTexture` obtained above. Because it aliases the pixel buffer's IOSurface, changes are immediately visible to AVFoundation when you commit the command buffer.

**Full render-into-buffer sketch:**

```swift
func renderEyeFrame(
    into pixelBuffer: CVMutablePixelBuffer,
    sourceTexture: MTLTexture,       // your live-generated content
    commandQueue: MTLCommandQueue,
    textureCache: CVMetalTextureCache,
    renderPipeline: MTLRenderPipelineState
) {
    guard let destTexture = metalTexture(from: pixelBuffer, cache: textureCache) else { return }

    let desc = MTLRenderPassDescriptor()
    desc.colorAttachments[0].texture = destTexture
    desc.colorAttachments[0].loadAction = .clear
    desc.colorAttachments[0].storeAction = .store

    let cmdBuf = commandQueue.makeCommandBuffer()!
    let enc = cmdBuf.makeRenderCommandEncoder(descriptor: desc)!
    enc.setRenderPipelineState(renderPipeline)
    enc.setFragmentTexture(sourceTexture, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()   // must be complete before enqueue
}
```

### 4. Build a Tagged CMReadySampleBuffer and Enqueue

```swift
import CoreMedia

func makeStereoPair(
    left: CVMutablePixelBuffer,
    right: CVMutablePixelBuffer,
    pts: CMTime,
    duration: CMTime
) -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
    let leftTags:  [CMTag] = [.videoLayerID(0), .stereoView(.leftEye),  .mediaType(.video)]
    let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)]

    let taggedBuffers: [CMTaggedDynamicBuffer] = [
        CMTaggedDynamicBuffer(tags: leftTags,  content: .pixelBuffer(CVReadOnlyPixelBuffer(left))),
        CMTaggedDynamicBuffer(tags: rightTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(right))),
    ]

    return CMReadySampleBuffer(
        taggedBuffers: taggedBuffers,
        formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: taggedBuffers),
        presentationTimeStamp: pts,
        duration: duration
    )
}
```

Call this on a background queue inside `requestMediaDataWhenReady(on:using:)`:

```swift
videoRenderer.requestMediaDataWhenReady(on: .global()) { [weak self] in
    guard let self else { return }
    while self.videoRenderer.isReadyForMoreMediaData {
        let (leftBuf, rightBuf) = self.generateNextEyePair()   // your render call
        let pts   = self.synchronizer.currentTime()
        let frame = makeStereoPair(left: leftBuf, right: rightBuf, pts: pts, duration: frameDuration)
        self.videoRenderer.enqueue(frame)
    }
}
// Start the clock.
synchronizer.setRate(1, time: .zero)
```

---

## Path B — ImmersiveSpace: CompositorServices / LayerRenderer

Use this when you need the lowest latency, full control over the render loop, head-pose-driven reprojection, or full-immersion content. You **must** be inside an `ImmersiveSpace` with `.full` or `.progressive` immersion style. This API is not available in a shared-space window.

### App entry point

```swift
@main
struct MyApp: App {
    var body: some Scene {
        ImmersiveSpace(id: "Stereo") {
            CompositorLayer { layerRenderer in
                let engine = StereoEngine(layerRenderer: layerRenderer)
                let thread = Thread { engine.runLoop() }
                thread.name = "StereoRenderThread"
                thread.start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
```

### Render loop skeleton

`LayerRenderer` vends a `LayerRenderer.Drawable` each frame. Each drawable contains an array of `LayerRenderer.Drawable.View` — one per eye. The `colorTextures` (and `depthTextures`) are standard `MTLTexture`s with `.textureType == .type2DArray` and two array slices when the layout is `.dedicated`; or separate textures when the layout is `.layered`.

```swift
import CompositorServices

final class StereoEngine {
    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    init(layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = device.makeCommandQueue()!
    }

    func runLoop() {
        while true {
            switch layerRenderer.state {
            case .paused:
                layerRenderer.waitUntilRunning()
                continue
            case .running:
                guard let frame = layerRenderer.queryNextFrame() else { continue }
                frame.startSubmission()
                renderFrame(frame)
                frame.endSubmission()
            case .invalidated:
                return
            @unknown default:
                continue
            }
        }
    }

    private func renderFrame(_ frame: LayerRenderer.Frame) {
        guard let drawable = frame.queryDrawable() else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // drawable.views is an array with one entry per eye.
        for (viewIndex, view) in drawable.views.enumerated() {
            let colorTarget = drawable.colorTextures[viewIndex]
            let depthTarget = drawable.depthTextures[viewIndex]

            let rpDesc = MTLRenderPassDescriptor()
            rpDesc.colorAttachments[0].texture     = colorTarget
            rpDesc.colorAttachments[0].loadAction  = .clear
            rpDesc.colorAttachments[0].storeAction = .store
            rpDesc.depthAttachment.texture          = depthTarget
            rpDesc.depthAttachment.loadAction       = .clear
            rpDesc.depthAttachment.storeAction      = .store

            // view.transform: the eye pose in world space (read from ARKit)
            // view.tangents:  FOV tangents for the projection matrix
            let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc)!
            encodeEye(enc, viewIndex: viewIndex, view: view)
            enc.endEncoding()
        }

        cmdBuf.commit()
        drawable.encodePresent(commandBuffer: cmdBuf)   // schedules compositor present
    }

    private func encodeEye(
        _ encoder: MTLRenderCommandEncoder,
        viewIndex: Int,
        view: LayerRenderer.Drawable.View
    ) {
        // Build your per-eye projection and view matrices from view.tangents / view.transform.
        // Encode your scene draw calls.
        // Feed your live AVPlayerItemVideoOutput texture here if desired.
    }
}
```

Key points:
- `frame.startSubmission()` / `frame.endSubmission()` bracket the work for that prediction time.
- `drawable.encodePresent(commandBuffer:)` tells the compositor when the command buffer that contains the final resolve is ready; call it on the **last** command buffer in the frame.
- The compositor handles reprojection automatically using the depth buffer you provide.

---

## Feeding AVPlayerItemVideoOutput Frames into Either Path

`AVPlayerItemVideoOutput` delivers decoded frames as `CVPixelBuffer`s at display time. For a side-by-side stereoscopic source, split each frame into left/right halves with `VTPixelTransferSession`. For an MV-HEVC source, AVFoundation will give you separate tagged buffers automatically when you opt in.

### Side-by-side source → per-eye CVPixelBuffers

```swift
import VideoToolbox

class SideBySideSplitter {
    let transferSession: VTPixelTransferSession
    let eyePool: CVPixelBufferPool

    init(eyeWidth: Int, eyeHeight: Int) {
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        self.transferSession = session!

        // Build a pool of the same format as the source but half the width.
        var attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String:  eyeWidth,
            kCVPixelBufferHeightKey as String: eyeHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        self.eyePool = pool!
    }

    func split(_ sideBySide: CVPixelBuffer) -> (left: CVPixelBuffer, right: CVPixelBuffer) {
        func extractEye(layerID: Int) -> CVPixelBuffer {
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, eyePool, &buf)
            let eyeWidth = CVPixelBufferGetWidth(sideBySide) / 2
            let offset   = Double(layerID) * Double(eyeWidth) - Double(eyeWidth) / 2.0
            let aperture: [CFString: Any] = [
                kCVImageBufferCleanApertureWidthKey:           eyeWidth,
                kCVImageBufferCleanApertureHeightKey:          CVPixelBufferGetHeight(sideBySide),
                kCVImageBufferCleanApertureHorizontalOffsetKey: offset,
                kCVImageBufferCleanApertureVerticalOffsetKey:  0,
            ]
            CVBufferSetAttachment(sideBySide, kCVImageBufferCleanApertureKey,
                                  aperture as CFDictionary, .shouldPropagate)
            VTSessionSetProperty(transferSession,
                                 key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_CropSourceToCleanAperture)
            VTPixelTransferSessionTransferImage(transferSession, from: sideBySide, to: buf!)
            return buf!
        }
        return (left: extractEye(layerID: 0), right: extractEye(layerID: 1))
    }
}
```

Once you have the two `CVPixelBuffer`s, pass them to `makeStereoPair` (Path A) or render them into the `LayerRenderer.Drawable` textures via `CVMetalTextureCache` (Path B).

### Pulling frames on a display-link cadence

```swift
let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
])
player.currentItem?.add(output)

// In your CADisplayLink / MTKView draw callback:
let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
if output.hasNewPixelBuffer(forItemTime: itemTime),
   let frame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
    let (left, right) = splitter.split(frame)
    // → enqueue to AVSampleBufferVideoRenderer (Path A)
    //   or blit into LayerRenderer textures (Path B)
}
```

---

## Constraints and Gotchas

| Constraint | Detail |
|-----------|--------|
| `VideoPlayerComponent(videoRenderer:)` owns the renderer | One `AVSampleBufferVideoRenderer` per `VideoPlayerComponent`; cannot be shared. |
| IOSurface backing is mandatory | Non-IOSurface `CVPixelBuffer`s cause a GPU stall or silent drop. Always set `kCVPixelBufferIOSurfacePropertiesKey`. |
| Enqueue on a background queue | `requestMediaDataWhenReady(on:using:)` calls back on your supplied queue. Blocking the main thread will cause dropped frames. |
| `LayerRenderer` needs ImmersiveSpace | `CompositorLayer` is only valid inside `ImmersiveSpace`. The shared-space `WindowGroup` does not expose per-eye drawables. |
| Prediction timing in LayerRenderer | Use `frame.predictedDisplayTime` and `drawable.frameTiming` to query the predicted head pose from ARKit at the correct time. Rendering with stale pose causes judder. |
| `waitUntilCompleted` before enqueue | If blitting Metal → CVPixelBuffer manually, the GPU work must complete before `videoRenderer.enqueue` is called. Prefer scheduling the enqueue as a completion handler on `cmdBuf` instead. |
| Tagged buffer format description | `CMTaggedBufferGroupFormatDescription(taggedBuffers:)` infers the format from the first buffer's pixel format. Both eyes must use identical dimensions and pixel formats. |
| Pixel format choice | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (YCbCr 4:2:0) matches the compositor's native format and avoids an implicit conversion. For HDR content use `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`. |
| `AVPlayerItemVideoOutput` does not output tagged stereo buffers | For MV-HEVC playback with per-frame access, use `AVAssetReader` + `AVAssetReaderTrackOutput` with opt-in stereo (set `containsStereoMultiviewVideo` characteristic awareness). `AVPlayerItemVideoOutput` returns the base (left) view only. |

---

## Quick Decision Guide

```
Need stereo in a normal window alongside other apps?
  └─ YES → Path A (VideoPlayerComponent + tagged CMSampleBuffer)
           Works in Shared Space. No ImmersiveSpace needed.
           Limited to RealityKit scene; no custom warp/shader on output.

Need a completely custom render loop with per-eye control,
head-locked content, or the lowest-latency path?
  └─ YES → Path B (CompositorServices / LayerRenderer)
           Requires ImmersiveSpace. Full Metal control.
           Compositor handles timewarp & reprojection using your depth buffer.

Source is an existing side-by-side or MV-HEVC video file?
  └─ Use AVPlayerItemVideoOutput (+ splitter for SBS) to pull frames,
     then route into whichever path above matches your display context.
```

---

## Reference

- [Rendering stereoscopic video with RealityKit](https://developer.apple.com/documentation/RealityKit/rendering-stereoscopic-video-with-realitykit)
- [Drawing fully immersive content using Metal](https://developer.apple.com/documentation/compositorservices/drawing-fully-immersive-content-using-metal)
- [Converting side-by-side 3D video to multiview HEVC](https://developer.apple.com/documentation/AVFoundation/converting-side-by-side-3d-video-to-multiview-hevc-and-spatial-video)
- [Processing spatial video with a custom compositor](https://developer.apple.com/documentation/AVFoundation/processing-spatial-video-with-a-custom-video-compositor)
- `VideoPlayerComponent` — RealityKit
- `AVSampleBufferVideoRenderer` — AVFoundation
- `CMTaggedDynamicBuffer` / `CMReadySampleBuffer` — CoreMedia
- `CVMetalTextureCacheCreateTextureFromImage` — CoreVideo
- `VTPixelTransferSession` — VideoToolbox
