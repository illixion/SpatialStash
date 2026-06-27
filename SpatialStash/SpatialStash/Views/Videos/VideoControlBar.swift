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

import SwiftUI

struct VideoControlBar: View {
    @Bindable var windowModel: VideoWindowModel

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
        .buttonStyle(.borderless)
        .help(windowModel.isPaused ? "Play" : "Pause")
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            let dur = max(windowModel.duration, 0.001)
            let progress = clamp(windowModel.currentTime / dur)
            let buffered = clamp(windowModel.bufferedEnd / dur)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 6)
                Capsule().fill(.white.opacity(0.35)).frame(width: CGFloat(w * buffered), height: 6)
                Capsule().fill(Color.accentColor).frame(width: CGFloat(w * progress), height: 6)

                if let a = windowModel.loopController.pointA {
                    marker(.green).position(x: CGFloat(w * clamp(a / dur)), y: 11)
                }
                if let b = windowModel.loopController.pointB {
                    marker(.red).position(x: CGFloat(w * clamp(b / dur)), y: 11)
                }

                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(radius: 2)
                    .position(x: CGFloat(w * progress), y: 11)
            }
            .frame(width: CGFloat(w), height: 22)
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
        }
        .frame(height: 22)
    }

    private func marker(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 3, height: 16)
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
        .buttonStyle(.borderless)
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
        .buttonStyle(.borderless)
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
        .buttonStyle(.borderless)
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
