/*
 Spatial Stash - Video Control Bar

 Custom SwiftUI transport controls for the 2D web video player, replacing
 Safari's built-in <video> controls. Drives the underlying <video> element
 entirely through the JS bridge (VideoWindowModel command closures bound by
 WebVideoPlayerView), and renders playback state reported back over the
 `videoPlayback` message channel.

 Layout: [play/pause] [elapsed] [========= scrubber =========] [duration] [A-B] [clear?] [mute]
 The scrubber shows the buffered range and A/B loop markers.
 */

import RAVEUI
import SwiftUI

struct VideoControlBar: View {
    @Bindable var windowModel: VideoWindowModel
    @State private var isScrubberHovering = false

    var body: some View {
        HStack(spacing: 16) {
            playPauseButton

            Text(Self.formatTime(windowModel.currentTime))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            scrubber

            Text(Self.formatTime(windowModel.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .leading)

            abLoopButton

            if windowModel.loopController.pointA != nil {
                clearLoopButton
            }

            muteButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: 820)
        .glassBackgroundEffect()
    }

    // MARK: - Play / Pause

    private var playPauseButton: some View {
        Button {
            windowModel.togglePlayPause()
        } label: {
            Image(systemName: windowModel.isPaused ? "play.fill" : "pause.fill")
                .font(.title2)
                .frame(width: 28)
        }
        .buttonStyle(.raveChrome)
        .help(windowModel.isPaused ? "Play" : "Pause")
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            let dur = max(windowModel.duration, 0.001)
            let progress = clamp(windowModel.currentTime / dur)
            let buffered = clamp(windowModel.bufferedEnd / dur)
            let isTargeted = isScrubberHovering || windowModel.isScrubbing
            let trackHeight: CGFloat = isTargeted ? 10 : 6
            let markerHeight: CGFloat = isTargeted ? 20 : 16
            let knobSize: CGFloat = isTargeted ? 24 : 18

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isTargeted ? .white.opacity(0.16) : .clear)
                    .frame(height: 32)

                Capsule().fill(.white.opacity(isTargeted ? 0.32 : 0.22)).frame(height: trackHeight)
                Capsule().fill(.white.opacity(isTargeted ? 0.48 : 0.35)).frame(width: CGFloat(w * buffered), height: trackHeight)
                Capsule().fill(Color.accentColor).frame(width: CGFloat(w * progress), height: trackHeight)

                if let a = windowModel.loopController.pointA {
                    marker(.green, height: markerHeight).position(x: CGFloat(w * clamp(a / dur)), y: 16)
                }
                if let b = windowModel.loopController.pointB {
                    marker(.red, height: markerHeight).position(x: CGFloat(w * clamp(b / dur)), y: 16)
                }

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.35), radius: isTargeted ? 5 : 2)
                    .overlay {
                        if isTargeted {
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .position(x: CGFloat(w * progress), y: 16)
            }
            .frame(width: CGFloat(w), height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !windowModel.isScrubbing { windowModel.beginScrub() }
                        windowModel.scrub(to: clamp(Double(value.location.x) / w) * dur)
                    }
                    .onEnded { value in
                        windowModel.endScrub(at: clamp(Double(value.location.x) / w) * dur)
                    }
            )
            .hoverEffect(.highlight)
            .onHover { hovering in
                isScrubberHovering = hovering
            }
            .animation(.easeInOut(duration: 0.12), value: isTargeted)
        }
        .frame(height: 32)
    }

    private func marker(_ color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 3, height: height)
    }

    // MARK: - A-B Loop

    private var abLoopButton: some View {
        Button {
            Task { await windowModel.loopController.handleButtonTap() }
        } label: {
            Image(systemName: windowModel.loopController.iconName)
                .font(.title3)
                .foregroundStyle(windowModel.loopController.isEngaged ? Color.accentColor : .primary)
                .frame(width: 28)
        }
        .buttonStyle(.raveChrome)
        .help(windowModel.loopController.helpText)
    }

    private var clearLoopButton: some View {
        Button {
            windowModel.loopController.clear()
        } label: {
            Image(systemName: "xmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.raveChrome)
        .help("Clear A-B Loop")
    }

    // MARK: - Mute

    private var muteButton: some View {
        Button {
            windowModel.toggleMute()
        } label: {
            Image(systemName: windowModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.title3)
                .frame(width: 28)
        }
        .buttonStyle(.raveChrome)
        .help(windowModel.isMuted ? "Unmute" : "Mute")
    }

    // MARK: - Helpers

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
