/*
 Hypnos - GPU Memory Monitor View

 Live-updating window that displays the current GPU memory allocation
 reported by Metal's device.currentAllocatedSize. Useful for comparing
 memory usage between compression modes (lossy vs lossless).
 */

import Metal
import RAVEDiagnostics
import SwiftUI

struct GPUMemoryMonitorView: View {
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow

    /// The latest reading. GPU allocation is the number this window exists for
    /// — it is what moves when texture compression changes, whereas the process
    /// footprint (which jetsam judges) barely does.
    @State private var reading = RAVEMemoryReading()

    /// Peak GPU allocation observed during this session
    @State private var peakAllocation: Int = 0

    /// Timer task for polling
    @State private var pollingTask: Task<Void, Never>?

    /// The Metal device reference
    private var device: MTLDevice? { MetalImageRenderer.shared?.device }

    private var currentAllocation: Int { reading.gpuAllocated ?? 0 }

    /// Recommended allocation size for the gauge maximum (in bytes).
    /// Vision Pro M2 has ~5.5 GB shared memory; use 3 GB as a reasonable
    /// upper bound for the gauge since the app won't use all of it.
    private let gaugeMax: Int = 3 * 1024 * 1024 * 1024 // 3 GB

    var body: some View {
        VStack(spacing: 24) {
            Text("GPU Memory")
                .font(.title2)
                .fontWeight(.semibold)

            Gauge(value: Double(currentAllocation), in: 0...Double(gaugeMax)) {
                Text("Allocated")
            } currentValueLabel: {
                Text(formatBytes(currentAllocation))
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(allocationColor)
            } minimumValueLabel: {
                Text("0")
                    .font(.caption2)
            } maximumValueLabel: {
                Text(formatBytes(gaugeMax))
                    .font(.caption2)
            }
            .gaugeStyle(.accessoryLinear)
            .tint(allocationGradient)

            HStack(spacing: 32) {
                StatBox(label: "Current", value: formatBytes(currentAllocation))
                StatBox(label: "Peak", value: formatBytes(peakAllocation))
                StatBox(label: "Windows", value: "\(appModel.openPhotoWindowCount)")
            }

            HStack(spacing: 32) {
                // The footprint is what jetsam counts and the headroom is what
                // it counts against — neither is derivable from the GPU figure,
                // and both come free with the shared probe.
                StatBox(label: "Footprint", value: optionalBytes(reading.processFootprint))
                StatBox(label: "Headroom", value: optionalBytes(reading.availableMemory))
            }

            HStack(spacing: 32) {
                StatBox(
                    label: "Compression",
                    value: appModel.useLossyTextureCompression ? "Lossy" : "Lossless"
                )
                StatBox(
                    label: "Per Window (avg)",
                    value: appModel.openPhotoWindowCount > 0
                        ? formatBytes(currentAllocation / max(appModel.openPhotoWindowCount, 1))
                        : "—"
                )
            }

            Button("Reset Peak") {
                peakAllocation = currentAllocation
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 300)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        // Only a separate window needs its own way back to the gallery; the
        // iOS sheet has a Done button.
        .ornament(
            visibility: PlatformCapabilities.supportsMultipleWindows ? .visible : .hidden,
            attachmentAnchor: .scene(.bottom)
        ) {
            HStack(spacing: 16) {
                Button {
                    appModel.showMainWindow(openWindow: openWindow)
                } label: {
                    Label("Gallery", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .glassBackgroundEffect()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        sample() // Immediate first read
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                sample()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func sample() {
        reading = RAVEMemoryProbe.reading(device: device)
        if currentAllocation > peakAllocation {
            peakAllocation = currentAllocation
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int) -> String {
        RAVEMemoryProbe.format(bytes)
    }

    private func optionalBytes(_ bytes: Int?) -> String {
        bytes.map(RAVEMemoryProbe.format) ?? "—"
    }

    private var allocationColor: Color {
        let fraction = Double(currentAllocation) / Double(gaugeMax)
        if fraction > 0.8 { return .red }
        if fraction > 0.5 { return .orange }
        return .green
    }

    private var allocationGradient: Gradient {
        Gradient(colors: [.green, .yellow, .orange, .red])
    }
}

// MARK: - Stat Box

private struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
