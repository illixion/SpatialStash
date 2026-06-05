/*
 Spatial Stash - Device Metrics

 Process-wide memory/state snapshot emitted to the RoboFrame backend over the
 existing slideshow WebSocket (see SlideshowSyncHub.telemetry + protocol.md
 `reportMetrics` / `reportLog`). Lets us diagnose the multi-window slideshow
 OOM *during active playback* rather than only from post-suspend jetsam logs,
 which already had the app trimmed/suspended (see
 .claude/research/jxl-decode-memory-oom.md).

 Gated behind the Console developer toggle — this is quasi-dev-mode telemetry,
 not always-on.
 */

import Darwin
import Foundation
import os

/// One process-wide telemetry sample. `deviceId`/`app` identify the emitter so
/// the server can bucket samples per app instance.
struct DeviceMetrics {
    let deviceId: String
    let app: String
    /// Real memory footprint as jetsam judges it (`phys_footprint`).
    let footprintMB: Int
    /// Headroom before our own per-process limit (`os_proc_available_memory`).
    let availableMB: Int
    /// Metal allocation (GPU-private textures), the same figure the GPU monitor shows.
    let gpuMB: Int
    let photoWindows: Int
    let slideshowWindows: Int
    /// Whether the oversized-decode / server-convert heuristic considers us pressured.
    let gpuHigh: Bool

    /// JSON payload for the `reportMetrics` WS frame.
    var payload: [String: Any] {
        [
            "deviceId": deviceId,
            "app": app,
            "footprintMB": footprintMB,
            "availableMB": availableMB,
            "gpuMB": gpuMB,
            "photoWindows": photoWindows,
            "slideshowWindows": slideshowWindows,
            "gpuHigh": gpuHigh,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ]
    }

    static func capture(deviceId: String, app: String, photoWindows: Int, slideshowWindows: Int) -> DeviceMetrics {
        let gpu = MetalImageRenderer.shared?.currentGPUAllocation ?? 0
        return DeviceMetrics(
            deviceId: deviceId,
            app: app,
            footprintMB: physFootprintBytes() / (1024 * 1024),
            availableMB: Int(os_proc_available_memory()) / (1024 * 1024),
            gpuMB: gpu / (1024 * 1024),
            photoWindows: photoWindows,
            slideshowWindows: slideshowWindows,
            gpuHigh: MetalImageRenderer.shared?.isGPUMemoryHigh ?? false
        )
    }

    /// `task_vm_info.phys_footprint` — the dirty + compressed + IOKit-mapped
    /// total the kernel uses for jetsam decisions. More truthful than
    /// `resident_size` (which omits compressed pages).
    private static func physFootprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
