/*
 PlayerLab - the film player on the Mac.

   JELLYFIN_TOKEN=… swift run PlayerLab

 Environment:
   JELLYFIN_TOKEN   API key (required; never logged)
   FILM_SERVER      Jellyfin base URL (default: servo over the tailnet)
   FILM_ITEM        item id (default: The Wild Robot, Dolby Vision P8.1)
   FILM_START       start position in seconds
   FILM_AUTOPLAY    1 to start playing once loaded
   FILM_SCRIPT      timed actions for unattended runs, e.g. "6:seek=1800;12:pause;14:play;20:quit"
                    (seconds after load : seek=<s> | play | pause | quit)

 Prints one telemetry line per second to stdout, so a run can be judged
 from its log as well as by eye.
 */

import AppKit
import CoreMedia
import FilmPlayback
import SwiftUI

@main
struct PlayerLab: App {
    @State private var player = FilmVideoPlayer()
    private let environment = ProcessInfo.processInfo.environment

    init() {
        setvbuf(stdout, nil, _IOLBF, 0) // line-buffered, so a redirected log can be followed live
        // An unbundled executable starts as a background process; make it a regular app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("PlayerLab") {
            LabView(player: player, environment: environment)
                .frame(minWidth: 960, minHeight: 540)
        }
    }
}

struct LabView: View {
    let player: FilmVideoPlayer
    let environment: [String: String]
    @State private var scrub: Double?
    @State private var now = 0.0

    var body: some View {
        VStack(spacing: 0) {
            FilmVideoView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            controls
                .padding(12)
        }
        .task { await run() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(player.isPlaying ? "Pause" : "Play") { player.isPlaying ? player.pause() : player.play() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("−10s") { player.seek(to: player.currentTime - 10) }
                Button("+10s") { player.seek(to: player.currentTime + 10) }
                Button("+5 min") { player.seek(to: player.currentTime + 300) }
                Slider(
                    value: Binding(get: { scrub ?? now }, set: { scrub = $0 }),
                    in: 0 ... max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrub {
                            player.seek(to: target)
                            scrub = nil
                        }
                    }
                )
                Text(Self.clock(scrub ?? now) + " / " + Self.clock(player.duration)).monospacedDigit()
            }
            Text(player.formatSummary).font(.caption.monospaced())
            Text(String(format: "%@ · segment %d · buffered %.1f s ahead · last seek %.0f ms",
                        player.status, player.currentSegment, player.bufferedUntil - now, player.lastSeekLatency * 1000))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func run() async {
        guard let token = environment["JELLYFIN_TOKEN"], !token.isEmpty else {
            print("PlayerLab: set JELLYFIN_TOKEN")
            return
        }
        let server = URL(string: environment["FILM_SERVER"] ?? "https://servo.akita-city.ts.net/jellyfin")!
        let item = environment["FILM_ITEM"] ?? "e586b2bba9cfb3cb27fb0ddfa602ac2f"
        let start = Double(environment["FILM_START"] ?? "") ?? 0
        await player.load(FilmServerClient(baseURL: server, token: token, itemID: item), startAt: start)
        print("PlayerLab: \(player.status) — \(player.formatSummary)")
        if environment["FILM_AUTOPLAY"] == "1" { player.play() }

        let script = Self.parse(environment["FILM_SCRIPT"] ?? "")
        let loaded = Date()
        var next = 0
        while !Task.isCancelled {
            now = player.currentTime
            let elapsed = Date().timeIntervalSince(loaded)
            while next < script.count, script[next].at <= elapsed {
                let action = script[next].action
                print(String(format: "PlayerLab: [%.1f s] %@", elapsed, action))
                switch action {
                case "play": player.play()
                case "pause": player.pause()
                case "quit": NSApplication.shared.terminate(nil)
                default:
                    if action.hasPrefix("seek="), let target = Double(action.dropFirst(5)) { player.seek(to: target) }
                }
                next += 1
            }
            if Int(elapsed * 4) % 4 == 0 {
                print(String(format: "PlayerLab: t=%.3f playing=%d seg=%d ahead=%.1f seek=%.0fms status=%@ layer=%d",
                             now, player.isPlaying ? 1 : 0, player.currentSegment, player.bufferedUntil - now,
                             player.lastSeekLatency * 1000, player.status, player.displayLayer.sampleBufferRenderer.status.rawValue))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func parse(_ script: String) -> [(at: Double, action: String)] {
        script.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]) else { return nil }
            return (at, String(parts[1]))
        }.sorted { $0.at < $1.at }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
