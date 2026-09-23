/*
 Hypnos - Atmos Object Spike player

 Hosts `AtmosSpikeStageView` together with a top-down map of the objects
 and the transport. On visionOS it is the content of its own window (a
 stand-in for the video player window the sources will eventually follow),
 with the transport in an ornament and tuning left in Settings. On iOS the
 same window id opens it as a tool sheet (`IOSWindowRouter`, which supplies
 the navigation bar and Done button), with tuning and telemetry below the map.
 */

import SwiftUI

struct AtmosSpikePlayerView: View {
    static let windowID = "atmos-spike-player"

    @Bindable private var model = AtmosSpikeModel.shared

    var body: some View {
        #if os(visionOS)
        ZStack {
            AtmosSpikeStageView()
            if model.showMap {
                AtmosSpikeMapView()
                    .padding(40)
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            AtmosSpikeTransport()
                .padding()
                .frame(width: 560)
                .glassBackgroundEffect()
        }
        #else
        Form {
            Section(model.loadedRemoteName ?? model.loadedScene?.lastPathComponent ?? "") {
                ZStack {
                    AtmosSpikeStageView()
                    AtmosSpikeMapView()
                }
                .aspectRatio(1, contentMode: .fit)
                AtmosSpikeTransport()
            }
            Section("Head Tracking") { AtmosSpikeHeadTrackingRow() }
            Section("Tuning") { AtmosSpikeTuning() }
            Section("Telemetry") { AtmosSpikeTelemetry() }
        }
        #endif
    }
}

/// Objects seen from above, front (the screen) at the top. The dot at the
/// centre is the listener; each object's colour follows its height (blue at
/// ear level, red at the ceiling) and its size follows its level.
struct AtmosSpikeMapView: View {
    private let model = AtmosSpikeModel.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                let halfWidth = CGFloat(model.roomHalfWidth)
                let halfDepth = CGFloat(model.roomHalfDepth)
                let scale = min(size.width / (2 * halfWidth), size.height / (2 * halfDepth)) * 0.9
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let room = CGRect(x: centre.x - halfWidth * scale, y: centre.y - halfDepth * scale,
                                  width: 2 * halfWidth * scale, height: 2 * halfDepth * scale)
                context.stroke(Path(roundedRect: room, cornerRadius: 8), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                var screen = Path()
                screen.move(to: CGPoint(x: room.minX + room.width * 0.2, y: room.minY))
                screen.addLine(to: CGPoint(x: room.maxX - room.width * 0.2, y: room.minY))
                context.stroke(screen, with: .color(.primary), lineWidth: 4)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)),
                             with: .color(.primary))

                let frame = model.currentFrame
                for element in model.elements where !element.isBed {
                    let p = model.state(of: element, frame: frame).pos
                    let point = CGPoint(x: centre.x + CGFloat(p.x) * halfWidth * scale,
                                        y: centre.y - CGFloat(p.y) * halfDepth * scale)
                    let level = model.levels.indices.contains(element.channel) ? CGFloat(model.levels[element.channel]) : 0
                    let radius = 4 + min(level * 60, 18)
                    let height = model.flattenHeights ? 0 : Double(max(0, min(p.z, 1)))
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                        with: .color(Color(hue: 0.62 * (1 - height), saturation: 0.8, brightness: 1).opacity(0.35 + min(level * 8, 0.65)))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct AtmosSpikeTransport: View {
    @Bindable private var model = AtmosSpikeModel.shared
    /// Scrubber position while dragging; nil follows playback.
    @State private var scrubSeconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    model.isPlaying ? model.pause() : model.play()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { model.seek(to: model.positionSeconds - 10) } label: {
                    Label("−10s", systemImage: "gobackward.10")
                }
                Button { model.seek(to: model.positionSeconds + 10) } label: {
                    Label("+10s", systemImage: "goforward.10")
                }
                Button { model.seek(to: 0) } label: {
                    Label("Restart", systemImage: "backward.end")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            // Seeks on release, so a drag across a film is one seek, not hundreds.
            Slider(
                value: Binding(get: { scrubSeconds ?? model.positionSeconds }, set: { scrubSeconds = $0 }),
                in: 0...max(model.durationSeconds, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubSeconds {
                        model.seek(to: target)
                        scrubSeconds = nil
                    }
                }
            )
            Text("\(Self.clock(scrubSeconds ?? model.positionSeconds)) / \(Self.clock(model.durationSeconds))")
                .font(.caption.monospaced())
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

struct AtmosSpikeTuning: View {
    @Bindable private var model = AtmosSpikeModel.shared

    var body: some View {
        Group {
            slider("Master", value: $model.masterGainDB, in: -24...12, unit: "dB")
            slider("LFE", value: $model.lfeGainDB, in: -24...10, unit: "dB")
            slider("Reverb", value: $model.reverbDB, in: -40...0, unit: "dB")
            slider("Room half-width", value: $model.roomHalfWidth, in: 0.5...5, unit: "m")
            slider("Room half-depth", value: $model.roomHalfDepth, in: 0.5...5, unit: "m")
            slider("Ceiling above ears", value: $model.roomHeight, in: 0...3, unit: "m")
            #if os(visionOS)
            slider("You, in front of the window", value: $model.listenerDistance, in: 0.3...4, unit: "m")
            Toggle("Show map", isOn: $model.showMap)
            #endif
            Toggle("Flatten heights (A/B vs no height)", isOn: $model.flattenHeights)
        }
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(String(format: "%.1f", value.wrappedValue)) \(unit)").font(.caption)
            Slider(value: value, in: range)
        }
    }
}

#if os(iOS)
/// Status and Recenter for the AirPods head tracking.
struct AtmosSpikeHeadTrackingRow: View {
    private let tracker = AtmosSpikeHeadTracker.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.status)
                Text(String(format: "yaw %+.0f°  pitch %+.0f°", tracker.yawDegrees, tracker.pitchDegrees))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Recenter") { tracker.recenter() }
                .buttonStyle(.bordered)
                .disabled(!tracker.isTracking)
        }
    }
}
#endif

struct AtmosSpikeTelemetry: View {
    private let model = AtmosSpikeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "Render rate: %.0f Hz (scene %.0f Hz)", model.measuredRate, model.audio?.sampleRate ?? 0))
            Text("Clock: \(model.clockReport)")
            if !model.streamReport.isEmpty {
                Text("Stream: \(model.streamReport)")
            }
        }
        .font(.caption.monospaced())
        .foregroundColor(.secondary)
        .textSelection(.enabled)
    }
}
