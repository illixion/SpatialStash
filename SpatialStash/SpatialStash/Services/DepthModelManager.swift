/*
 Spatial Stash - Depth Model Manager

 In-app download + management of the Core ML monocular-depth models that power
 higher-quality fake-3D video. Downloads straight from Apple's canonical
 Hugging Face repo (apple/coreml-depth-anything-v2-small) — nothing is re-hosted.

 Each model is a `.mlpackage` (a directory of exactly three files with a fixed
 layout), so we fetch those files via HF's `resolve/main/…` URLs, rebuild the
 package in the managed store (DepthModelStore), and let Core ML compile it on
 first use. File sizes and SHA-256 checksums come from HF's tree API, so a
 truncated/corrupt download fails loudly rather than installing a broken model.

 Without any model the warp falls back to a lightweight heuristic, so this is
 purely an optional quality upgrade. A newly-installed model takes effect the
 next time a fake-3D video is opened (the running StereoPump keeps its provider).
 */

import CryptoKit
import Foundation
import os

@MainActor
@Observable
final class DepthModelManager {
    static let shared = DepthModelManager()

    /// A downloadable model offered in Settings and the video ViewMode menu. The
    /// F32 variants are intentionally omitted — negligible on-device quality gain
    /// for ~2× the bytes.
    struct Variant: Identifiable, Hashable, Sendable {
        /// Package base name — also the installed name / picker tag,
        /// e.g. `DepthAnythingV2SmallF16`.
        let name: String
        let displayName: String
        let subtitle: String
        let approxBytes: Int64
        var id: String { name }
    }

    static let variants: [Variant] = [
        Variant(name: "DepthAnythingV2SmallF16",
                displayName: "DepthAnything V2 (F16)",
                subtitle: "Best quality · recommended",
                approxBytes: 49_820_000),
        Variant(name: "DepthAnythingV2SmallF16INT8",
                displayName: "DepthAnything V2 (INT8)",
                subtitle: "Quantized · smaller, a touch faster",
                approxBytes: 25_400_000),
        Variant(name: "DepthAnythingV2SmallF16P6",
                displayName: "DepthAnything V2 (6-bit)",
                subtitle: "Palettized · smallest",
                approxBytes: 19_050_000),
        Variant(name: "DepthAnythingV2SmallF16P8",
                displayName: "DepthAnything V2 (8-bit)",
                subtitle: "Palettized · small",
                approxBytes: 25_260_000)
    ]

    private static let repoBase = "https://huggingface.co/apple/coreml-depth-anything-v2-small"
    private static let treeAPI = "https://huggingface.co/api/models/apple/coreml-depth-anything-v2-small/tree/main?recursive=true"
    /// The three files inside every `…Small….mlpackage`, in a fixed layout.
    private static let packageFiles = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin"
    ]

    /// Base names of installed models (managed store). Observable.
    private(set) var installedNames: [String] = []
    /// Download progress (0…1) keyed by variant name; a key is present only while
    /// that variant is downloading. Observable.
    private(set) var progress: [String: Double] = [:]
    /// Last download error, surfaced in Settings. Observable.
    private(set) var errorMessage: String?

    private init() {
        importInboxIfNeeded()
    }

    // MARK: State

    /// Drain the Documents inbox into the managed store, then refresh the list.
    func importInboxIfNeeded() {
        DepthModelStore.importInboxModels()
        refresh()
    }

    func refresh() {
        installedNames = DepthModelStore.installedModelNames()
    }

    func isInstalled(_ variant: Variant) -> Bool { installedNames.contains(variant.name) }
    func isDownloading(_ variant: Variant) -> Bool { progress[variant.name] != nil }
    var isAnyDownloading: Bool { !progress.isEmpty }

    func delete(_ name: String) {
        DepthModelStore.deleteModel(named: name)
        refresh()
    }

    /// Friendly label for an arbitrary installed model name (falls back to raw).
    static func displayName(for name: String) -> String {
        variants.first { $0.name == name }?.displayName ?? name
    }

    // MARK: Download

    func download(_ variant: Variant) async {
        guard progress[variant.name] == nil else { return }
        errorMessage = nil
        progress[variant.name] = 0
        do {
            try await performDownload(variant)
            refresh()
            AppLogger.videoWindow.info("Depth model installed: \(variant.name, privacy: .public)")
        } catch {
            errorMessage = "Couldn't download \(variant.displayName): \(error.localizedDescription)"
            AppLogger.videoWindow.error("Depth model download failed (\(variant.name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        progress[variant.name] = nil
    }

    private func setProgress(_ name: String, _ value: Double) {
        // Only update while still downloading (guards against late callbacks).
        guard progress[name] != nil else { return }
        progress[name] = value
    }

    private func performDownload(_ variant: Variant) async throws {
        let fm = FileManager.default
        let pkg = "\(variant.name).mlpackage"

        // Best-effort metadata (per-file size + SHA-256) from HF's tree API.
        var sizes: [String: Int64] = [:]
        var hashes: [String: String] = [:]
        if let entries = try? await fetchTree() {
            for e in entries where e.type == "file" && e.path.hasPrefix(pkg + "/") {
                let rel = String(e.path.dropFirst(pkg.count + 1))
                sizes[rel] = e.lfs?.size ?? e.size
                if let oid = e.lfs?.oid { hashes[rel] = oid }
            }
        }
        let totalBytes = Self.packageFiles.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        let effectiveTotal = totalBytes > 0 ? totalBytes : variant.approxBytes

        // Assemble into a temp package dir, then move into the store atomically.
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tmpPkg = tmpRoot.appendingPathComponent(pkg, isDirectory: true)
        try fm.createDirectory(at: tmpPkg, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        var completedBytes: Int64 = 0
        for rel in Self.packageFiles {
            guard let fileURL = URL(string: "\(Self.repoBase)/resolve/main/\(pkg)/\(rel)") else {
                throw DownloadError.badURL
            }
            // weight.bin dominates; if sizes are unknown, drive the bar off it.
            let expected = sizes[rel] ?? (rel.hasSuffix("weight.bin") ? effectiveTotal : 0)
            let base = completedBytes
            let denom = Double(effectiveTotal)
            let downloader = FileDownloader(expectedBytes: expected) { [weak self] fraction in
                let done = Double(base) + fraction * Double(max(expected, 0))
                let overall = denom > 0 ? min(1.0, done / denom) : 0
                Task { @MainActor in self?.setProgress(variant.name, overall) }
            }

            let tempFile = try await downloader.download(from: fileURL)
            if let want = hashes[rel] {
                guard let got = Self.sha256Hex(of: tempFile), got == want.lowercased() else {
                    try? fm.removeItem(at: tempFile)
                    throw DownloadError.checksumMismatch(rel)
                }
            }
            let dest = tmpPkg.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tempFile, to: dest)
            completedBytes += (sizes[rel] ?? 0)
        }

        let finalURL = DepthModelStore.modelsDirectory.appendingPathComponent(pkg)
        try? fm.removeItem(at: finalURL)
        try fm.moveItem(at: tmpPkg, to: finalURL)
    }

    // MARK: HF tree metadata

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let oid: String; let size: Int64? }
    }

    private func fetchTree() async throws -> [TreeEntry] {
        guard let url = URL(string: Self.treeAPI) else { throw DownloadError.badURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([TreeEntry].self, from: data)
    }

    // MARK: Helpers

    private static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum DownloadError: LocalizedError {
        case badURL
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid download URL."
            case .checksumMismatch(let file): return "Checksum mismatch (\(file))."
            }
        }
    }
}

// MARK: - FileDownloader

/// Delegate-driven download with byte progress, wrapped in async/await. Uses the
/// download-delegate's `didFinishDownloadingTo` (which fires while the temp file
/// still exists) to relocate it and resume the continuation, so file ownership is
/// unambiguous. `@unchecked Sendable`: the continuation is set before `resume()`
/// and consumed once on the session's delegate queue.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onFraction: @Sendable (Double) -> Void
    private var lastReported = -1.0
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession!

    init(expectedBytes: Int64, onFraction: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onFraction = onFraction
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else { return }
        let fraction = min(1.0, Double(totalBytesWritten) / Double(total))
        // Throttle: forward only on ~1% steps (and always the final one).
        if fraction - lastReported >= 0.01 || fraction >= 1.0 {
            lastReported = fraction
            onFraction(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            return
        }
        // `location` is deleted once this returns — move it somewhere stable now.
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
