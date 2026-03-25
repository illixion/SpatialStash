/*
 Spatial Stash - GPU Memory Monitor View

 Live-updating window that displays the current GPU memory allocation
 reported by Metal's device.currentAllocatedSize. Useful for comparing
 memory usage between compression modes (lossy vs lossless).
 */

import Metal
import SwiftUI

struct GPUMemoryMonitorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    /// Current GPU allocation in bytes, polled on a timer
    @State private var currentAllocation: Int = 0

    /// Peak allocation observed during this session
    @State private var peakAllocation: Int = 0

    /// Timer task for polling
    @State private var pollingTask: Task<Void, Never>?

    /// The Metal device reference
    private var device: MTLDevice? { MetalImageRenderer.shared?.device }

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
        .ornament(attachmentAnchor: .scene(.bottom)) {
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
        guard let device else { return }
        currentAllocation = device.currentAllocatedSize
        if currentAllocation > peakAllocation {
            peakAllocation = currentAllocation
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
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
