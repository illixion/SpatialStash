/*
 Spatial Stash - Depth Conversion Manager

 App-wide coordinator for offline fake-3D depth conversions: a FIFO of
 one-at-a-time jobs (conversion saturates the ANE, so parallel jobs would just
 fight each other — and the realtime fake-3D preview), each downloading the
 source when it's remote (AVAssetReader needs a local file), then running
 DepthConverter, then publishing completion so open video windows can offer
 "3D ready".

 @Observable: views bind to `activeJob` for progress, `lastCompleted` /
 `lastError` for the ready pill and failure toast. Jobs are keyed by video
 identity; enqueueing an identity that's already active or pending is a no-op.

 If the app backgrounds mid-conversion the task suspends with the app and
 resumes on foreground (no background-processing entitlement); a partial entry
 is deleted on cancel/failure so it can never be mistaken for a complete cache.
 */

import Foundation
import Observation
import os

@MainActor
@Observable
final class DepthConversionManager {
    static let shared = DepthConversionManager()

    struct Request: Equatable, Sendable {
        let videoIdentity: String
        let title: String?
        let sourceURL: URL
        /// Stash API key for authenticated downloads (nil for local files).
        let apiKey: String?
    }

    enum Phase: Equatable {
        case downloading(Double)
        case converting(Double)

        var label: String {
            switch self {
            case .downloading(let p):
                // Live-transcode downloads are chunked (no Content-Length), so
                // the fraction stays 0 — don't show a stuck "0%".
                return p > 0.001 ? "Downloading… \(Int(p * 100))%" : "Downloading…"
            case .converting(let p):
                return "Converting… \(Int(p * 100))%"
            }
        }
    }

    struct ActiveJob {
        let request: Request
        var phase: Phase
        /// Presentation time (seconds) depth has been emitted up to — the
        /// readable frontier of the growing cache entry.
        var frontierSeconds: Double = 0
    }

    struct CompletionEvent: Equatable {
        let videoIdentity: String
        let date: Date
    }

    struct FailureEvent: Equatable {
        let videoIdentity: String
        let message: String
        let date: Date
    }

    private(set) var activeJob: ActiveJob?
    private(set) var pending: [Request] = []
    /// Most recent successful conversion — video windows observe this to show
    /// the "3D ready" prompt.
    private(set) var lastCompleted: CompletionEvent?
    private(set) var lastError: FailureEvent?

    var isConverting: Bool { activeJob != nil }

    /// Measured conversion speed in video-seconds per wall-second (EMA); 0
    /// until enough samples exist.
    private(set) var conversionRate: Double = 0
    @ObservationIgnored private var lastFrontierSample: (wall: CFAbsoluteTime, frontier: Double)?

    /// Frontier + rate for the progressive-engage math, or nil unless this
    /// video is actively converting with a usable rate estimate.
    func progressiveStatus(videoIdentity: String) -> (frontier: Double, rate: Double)? {
        guard let activeJob,
              activeJob.request.videoIdentity == videoIdentity,
              case .converting = activeJob.phase,
              activeJob.frontierSeconds > 0,
              conversionRate > 0 else { return nil }
        return (activeJob.frontierSeconds, conversionRate)
    }

    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var currentConverter: DepthConverter?
    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var downloadObservation: NSKeyValueObservation?

    private init() {}

    // MARK: Query

    func isProcessing(videoIdentity: String) -> Bool {
        activeJob?.request.videoIdentity == videoIdentity
            || pending.contains { $0.videoIdentity == videoIdentity }
    }

    /// The active job's phase for a specific video, or nil.
    func phase(for videoIdentity: String) -> Phase? {
        guard let activeJob, activeJob.request.videoIdentity == videoIdentity else { return nil }
        return activeJob.phase
    }

    // MARK: Control

    /// Queue a conversion. No-op when this video is already active or pending.
    func enqueue(_ request: Request) {
        guard !isProcessing(videoIdentity: request.videoIdentity) else { return }
        pending.append(request)
        startNextIfIdle()
    }

    /// Cancel the job for a video, whether active or still queued.
    func cancel(videoIdentity: String) {
        pending.removeAll { $0.videoIdentity == videoIdentity }
        guard activeJob?.request.videoIdentity == videoIdentity else { return }
        currentConverter?.cancel()
        downloadTask?.cancel()
        currentTask?.cancel()
    }

    // MARK: Execution

    private func startNextIfIdle() {
        guard activeJob == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        activeJob = ActiveJob(request: request, phase: request.sourceURL.isFileURL ? .converting(0) : .downloading(0))
        currentTask = Task { await self.run(request) }
    }

    private func run(_ request: Request) async {
        var downloadedURL: URL?
        defer {
            if let downloadedURL {
                try? FileManager.default.removeItem(at: downloadedURL)
            }
            currentConverter = nil
            currentTask = nil
            downloadTask = nil
            downloadObservation = nil
            activeJob = nil
            conversionRate = 0
            lastFrontierSample = nil
            startNextIfIdle()
        }

        do {
            let localURL: URL
            if request.sourceURL.isFileURL {
                localURL = request.sourceURL
            } else {
                localURL = try await download(request)
                downloadedURL = localURL
            }

            activeJob?.phase = .converting(0)
            let converter = DepthConverter()
            currentConverter = converter
            let converterRequest = DepthConverter.Request(
                videoIdentity: request.videoIdentity,
                title: request.title,
                localFileURL: localURL
            )
            _ = try await converter.convert(request: converterRequest) { progress, frontier in
                Task { @MainActor in
                    self.updateConversionProgress(identity: request.videoIdentity, fraction: progress, frontier: frontier)
                }
            }
            lastCompleted = CompletionEvent(videoIdentity: request.videoIdentity, date: Date())
            AppLogger.videoCache.info("Depth conversion finished for \(request.videoIdentity, privacy: .private)")
        } catch {
            if isCancellation(error) {
                AppLogger.videoCache.info("Depth conversion cancelled for \(request.videoIdentity, privacy: .private)")
            } else {
                AppLogger.videoCache.error("Depth conversion failed for \(request.videoIdentity, privacy: .private): \(error.localizedDescription, privacy: .public)")
                lastError = FailureEvent(
                    videoIdentity: request.videoIdentity,
                    message: error.localizedDescription,
                    date: Date()
                )
            }
        }
    }

    private func updateConversionProgress(identity: String, fraction: Double, frontier: Double) {
        guard activeJob?.request.videoIdentity == identity else { return }
        activeJob?.phase = .converting(fraction)
        activeJob?.frontierSeconds = frontier
        // Rate EMA over ≥0.5s windows — smooth enough for the engage math,
        // responsive enough to notice thermal slowdown.
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastFrontierSample {
            let dt = now - last.wall
            if dt >= 0.5, frontier > last.frontier {
                let instant = (frontier - last.frontier) / dt
                conversionRate = conversionRate == 0 ? instant : conversionRate * 0.7 + instant * 0.3
                lastFrontierSample = (now, frontier)
            }
        } else {
            lastFrontierSample = (now, frontier)
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case DepthConversionError.cancelled = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: Download

    /// Download a remote source to a temp file (same pattern as the MV-HEVC
    /// path in StereoscopicVideoPlayer). Cancelled via `downloadTask`.
    private func download(_ request: Request) async throws -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let downloadDir = cachesDir.appendingPathComponent("DepthConversionDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let key = DepthCacheStore.entryKey(videoIdentity: request.videoIdentity, modelName: "src")
        let destinationURL = downloadDir.appendingPathComponent("\(key).mp4")
        try? FileManager.default.removeItem(at: destinationURL)

        var urlRequest = URLRequest(url: request.sourceURL)
        if let apiKey = request.apiKey, !apiKey.isEmpty {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "ApiKey")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: urlRequest) { tempURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL,
                      let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(throwing: URLError(.badServerResponse, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned status \(statusCode)"
                    ]))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            self.downloadObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
                Task { @MainActor in
                    guard self.activeJob?.request.videoIdentity == request.videoIdentity else { return }
                    self.activeJob?.phase = .downloading(progress.fractionCompleted)
                }
            }
            self.downloadTask = task
            task.resume()
        }
    }
}
