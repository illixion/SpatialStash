/*
 Spatial Stash - Video Chunk Downloader

 Downloads video in chunks using byte-range requests for streaming conversion.
 */

import Foundation

/// Information about a video stream for chunked downloading
struct VideoStreamInfo: Sendable {
    let totalDuration: TimeInterval
    let totalBytes: Int64
    let estimatedBytesPerSecond: Double
    let contentType: String

    /// Estimate chunk count for a given chunk duration
    func estimatedChunkCount(chunkDuration: TimeInterval) -> Int {
        Int(ceil(totalDuration / chunkDuration))
    }
}

/// A downloaded video chunk
struct VideoChunk: Sendable {
    let index: Int
    let data: Data
    let startTime: TimeInterval
    let estimatedDuration: TimeInterval
    let byteRange: Range<Int64>
    let isLast: Bool
}

/// Errors that can occur during chunk downloading
enum VideoChunkError: Error, LocalizedError {
    case invalidResponse
    case downloadFailed(String)
    case rangeNotSupported
    case serverError(Int)
    case invalidContentLength

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .rangeNotSupported:
            return "Server does not support byte-range requests"
        case .serverError(let code):
            return "Server error: \(code)"
        case .invalidContentLength:
            return "Could not determine video size"
        }
    }
}

/// Downloads video chunks using byte-range requests
actor VideoChunkDownloader {
    private let session: URLSession
    private let chunkDuration: TimeInterval

    /// Default estimated bitrate for initial chunk size calculation (5 Mbps)
    private let defaultBitrate: Double = 5_000_000

    init(chunkDuration: TimeInterval = 20.0) {
        self.chunkDuration = chunkDuration

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
    }

    /// Probe video to get stream information
    /// - Parameters:
    ///   - url: The video stream URL
    ///   - apiKey: Optional API key for authentication
    /// - Returns: Information about the video stream
    func probeVideo(url: URL, apiKey: String?) async throws -> VideoStreamInfo {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "ApiKey")
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoChunkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw VideoChunkError.serverError(httpResponse.statusCode)
        }

        // Check if server supports range requests
        let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
        if acceptRanges == "none" {
            throw VideoChunkError.rangeNotSupported
        }

        let contentLength = httpResponse.expectedContentLength
        guard contentLength > 0 else {
            throw VideoChunkError.invalidContentLength
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"

        // Estimate duration based on typical bitrates
        // This is a rough estimate; actual duration will be refined during playback
        let estimatedBytesPerSecond = defaultBitrate / 8
        let estimatedDuration = Double(contentLength) / estimatedBytesPerSecond

        return VideoStreamInfo(
            totalDuration: estimatedDuration,
            totalBytes: contentLength,
            estimatedBytesPerSecond: estimatedBytesPerSecond,
            contentType: contentType
        )
    }

    /// Calculate byte range for a chunk
    /// - Parameters:
    ///   - chunkIndex: The chunk index (0-based)
    ///   - videoInfo: Video stream information
    /// - Returns: Byte range for the chunk
    func byteRangeForChunk(index chunkIndex: Int, videoInfo: VideoStreamInfo) -> Range<Int64> {
        let bytesPerChunk = Int64(chunkDuration * videoInfo.estimatedBytesPerSecond)
        let startByte = Int64(chunkIndex) * bytesPerChunk
        let endByte = min(startByte + bytesPerChunk, videoInfo.totalBytes)
        return startByte..<endByte
    }

    /// Download a specific chunk by index
    /// - Parameters:
    ///   - url: The video stream URL
    ///   - apiKey: Optional API key for authentication
    ///   - chunkIndex: The chunk index to download (0-based)
    ///   - videoInfo: Video stream information from probeVideo
    /// - Returns: The downloaded chunk
    func downloadChunk(
        url: URL,
        apiKey: String?,
        chunkIndex: Int,
        videoInfo: VideoStreamInfo
    ) async throws -> VideoChunk {
        let byteRange = byteRangeForChunk(index: chunkIndex, videoInfo: videoInfo)

        var request = URLRequest(url: url)
        request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound - 1)", forHTTPHeaderField: "Range")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "ApiKey")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoChunkError.invalidResponse
        }

        // 206 Partial Content is expected for range requests
        guard httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
            throw VideoChunkError.serverError(httpResponse.statusCode)
        }

        let startTime = Double(chunkIndex) * chunkDuration
        let isLast = byteRange.upperBound >= videoInfo.totalBytes

        return VideoChunk(
            index: chunkIndex,
            data: data,
            startTime: startTime,
            estimatedDuration: chunkDuration,
            byteRange: byteRange,
            isLast: isLast
        )
    }

    /// Calculate total number of chunks for a video
    func totalChunks(for videoInfo: VideoStreamInfo) -> Int {
        videoInfo.estimatedChunkCount(chunkDuration: chunkDuration)
    }

    /// Download multiple chunks concurrently
    /// - Parameters:
    ///   - url: The video stream URL
    ///   - apiKey: Optional API key for authentication
    ///   - chunkIndices: Array of chunk indices to download
    ///   - videoInfo: Video stream information
    /// - Returns: Array of downloaded chunks (may be fewer than requested if some fail)
    func downloadChunks(
        url: URL,
        apiKey: String?,
        chunkIndices: [Int],
        videoInfo: VideoStreamInfo
    ) async -> [VideoChunk] {
        await withTaskGroup(of: VideoChunk?.self) { group in
            for index in chunkIndices {
                group.addTask {
                    try? await self.downloadChunk(
                        url: url,
                        apiKey: apiKey,
                        chunkIndex: index,
                        videoInfo: videoInfo
                    )
                }
            }

            var chunks: [VideoChunk] = []
            for await chunk in group {
                if let chunk = chunk {
                    chunks.append(chunk)
                }
            }

            return chunks.sorted { $0.index < $1.index }
        }
    }
}
