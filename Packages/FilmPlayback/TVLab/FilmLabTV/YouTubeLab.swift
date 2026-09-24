/*
 Hypnos - on-device YouTube playback spike

 Can a YouTube video play in our own AVPlayer with no web-yt-dlp backend?
 YouTube's player API, asked as its visionOS app (the client yt-dlp now
 defaults to), answers with an HLS master playlist up to 2160p60, VP9
 Profile 2 PQ included, and needs neither a PO token nor the web player's
 JavaScript. The one extra step is a visitor id from the watch page;
 without it the API answers "Sign in to confirm you're not a bot".

 Launch with `-YouTube <video id>` [`-YouTubeVariant <codec>`]; `TVLab/check-tv.sh --youtube <id>`
 plays it and reads the TV's input signal while it does.
 */

import AVFoundation
import AVKit
import SwiftUI
import VideoToolbox

enum YouTubeResolver {
    struct Streams {
        var hls: URL?
        var status: String
    }

    // The values yt-dlp 2026.08.19 sends for its `visionos` client.
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let client: [String: String] = [
        "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
        "deviceModel": "RealityDevice17,1", "userAgent": agent,
        "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "en", "gl": "US",
    ]

    static func resolve(_ id: String) async throws -> Streams {
        var page = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
        page.setValue(agent, forHTTPHeaderField: "User-Agent")
        let html = String(decoding: try await URLSession.shared.data(for: page).0, as: UTF8.self)
        let visitor = html.firstMatch(of: #/"VISITOR_DATA":"([^"]+)"/#).map { String($0.1) }

        var context = client
        if let visitor { context["visitorData"] = visitor }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": context], "videoId": id, "contentCheckOk": true, "racyCheckOk": true,
        ])
        for (field, value) in ["Content-Type": "application/json", "User-Agent": agent, "X-YouTube-Client-Name": "101",
                               "X-YouTube-Client-Version": "1.02", "Origin": "https://www.youtube.com"] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let json = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: request).0) as? [String: Any]
        let playability = json?["playabilityStatus"] as? [String: Any]
        let streaming = json?["streamingData"] as? [String: Any]
        return Streams(
            hls: (streaming?["hlsManifestUrl"] as? String).flatMap(URL.init(string:)),
            status: [playability?["status"], playability?["reason"]].compactMap { $0 as? String }.joined(separator: " ")
        )
    }
}

struct YouTubeLabView: View {
    let videoID: String
    @State private var player = AVPlayer()
    @State private var report = "Resolving…"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SystemPlayer(player: player).ignoresSafeArea()
            Text(report)
                .font(.caption2.monospaced())
                .padding(12)
                .background(.black.opacity(0.5))
                .padding(40)
        }
        .task { await run() }
    }

    private func run() async {
        // YouTube's 4K and HDR ladders are VP9 (and AV1). AVFoundation only
        // decodes them once the app opts in to the supplemental decoders.
        let before = [kCMVideoCodecType_VP9, kCMVideoCodecType_AV1].map(VTIsHardwareDecodeSupported)
        if #available(tvOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        let after = [kCMVideoCodecType_VP9, kCMVideoCodecType_AV1].map(VTIsHardwareDecodeSupported)
        say("Hardware decode VP9/AV1: before \(before), after \(after)")
        let streams: YouTubeResolver.Streams
        do { streams = try await YouTubeResolver.resolve(videoID) } catch {
            say("Resolve failed: \(error.localizedDescription)")
            return
        }
        say("Player API: \(streams.status), HLS \(streams.hls != nil ? "yes" : "no")")
        guard var url = streams.hls else { return }
        if let codec = UserDefaults.standard.string(forKey: "YouTubeVariant") {
            // One variant's own playlist (the last listed whose CODECS contain
            // `codec`, the highest resolution), bypassing AVPlayer's choice.
            guard let master = try? await URLSession.shared.data(from: url).0 else { return }
            let lines = String(decoding: master, as: UTF8.self).components(separatedBy: "\n")
            guard let pick = lines.indices.last(where: { lines[$0].hasPrefix("#EXT-X-STREAM-INF") && lines[$0].contains(codec) }),
                  let variant = URL(string: lines[pick + 1]) else {
                say("No variant with \(codec)")
                return
            }
            say("Variant: \(lines[pick].prefix(160))")
            url = variant
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            let event = item.accessLog()?.events.last
            var codec = "?", transfer = "?"
            if let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack,
               let format = try? await track.load(.formatDescriptions).first {
                codec = CMFormatDescriptionGetMediaSubType(format).fourCC
                transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? "-"
            }
            say(String(format: "t=%.1f %@ %@ %@ indicated=%.1fMbps observed=%.1fMbps stalls=%d dropped=%d%@",
                       player.currentTime().seconds, "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))",
                       codec, transfer, (event?.indicatedBitrate ?? 0) / 1e6, (event?.observedBitrate ?? 0) / 1e6,
                       event?.numberOfStalls ?? -1, event?.numberOfDroppedVideoFrames ?? -1,
                       item.error.map { " error=\($0.localizedDescription)" } ?? ""))
        }
    }

    private func say(_ line: String) {
        print("FilmLabTV: \(line)")
        report = line
    }
}

/// AVPlayerViewController, which states the content's display criteria to the
/// TV itself (appliesPreferredDisplayCriteriaAutomatically).
private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_: AVPlayerViewController, context _: Context) {}
}

private extension FourCharCode {
    var fourCC: String {
        String(bytes: [24, 16, 8, 0].map { UInt8(self >> $0 & 0xFF) }, encoding: .ascii) ?? "\(self)"
    }
}
