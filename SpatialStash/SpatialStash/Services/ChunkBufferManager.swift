/*
 Spatial Stash - Chunk Buffer Manager

 Manages converted MV-HEVC chunks for seamless stereoscopic video playback.
 Handles buffering, chunk transitions, and looping.
 */

import AVFoundation

/// State of the chunk buffer
enum ChunkBufferState: Equatable, Sendable {
    case empty
    case buffering(progress: Double)
    case ready
    case playing
    case error(String)

    static func == (lhs: ChunkBufferState, rhs: ChunkBufferState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.ready, .ready), (.playing, .playing):
            return true
        case (.buffering(let p1), .buffering(let p2)):
            return p1 == p2
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        default:
            return false
        }
    }
}

/// A buffered chunk ready for playback
struct BufferedChunk: Sendable {
    let index: Int
    let fileURL: URL
    let duration: CMTime
    let isLast: Bool
}

/// Manages converted MV-HEVC chunks for seamless playback
actor ChunkBufferManager {
    // Buffer configuration
    private let minBufferAhead: Int
    private let maxBufferAhead: Int

    // State
    private var chunks: [Int: BufferedChunk] = [:]
    private var currentChunkIndex: Int = 0
    private var totalChunks: Int = 0
    private var isLooping: Bool = true

    // Current state (accessed via async methods)
    private var currentState: ChunkBufferState = .empty

    init(minBufferAhead: Int = 2, maxBufferAhead: Int = 4) {
        self.minBufferAhead = minBufferAhead
        self.maxBufferAhead = maxBufferAhead
    }

    /// Get current buffer state
    var state: ChunkBufferState {
        currentState
    }

    /// Configure the buffer for a new video
    /// - Parameters:
    ///   - totalChunks: Total number of chunks in the video
    ///   - looping: Whether the video should loop
    func configure(totalChunks: Int, looping: Bool = true) {
        self.totalChunks = totalChunks
        self.isLooping = looping
        self.chunks.removeAll()
        self.currentChunkIndex = 0
        self.currentState = .empty
    }

    /// Add a converted chunk to the buffer
    func addChunk(_ convertedChunk: ConvertedChunk, isLast: Bool = false) {
        let bufferedChunk = BufferedChunk(
            index: convertedChunk.index,
            fileURL: convertedChunk.fileURL,
            duration: convertedChunk.duration,
            isLast: isLast
        )

        chunks[convertedChunk.index] = bufferedChunk

        // Clean up old chunks that are too far behind
        cleanupOldChunks()

        // Update state
        updateBufferState()
    }

    /// Get the current chunk for playback
    func getCurrentChunk() -> BufferedChunk? {
        chunks[currentChunkIndex]
    }

    /// Advance to the next chunk and return it
    /// - Returns: The next chunk, or nil if not available
    func advanceToNextChunk() -> BufferedChunk? {
        let nextIndex: Int

        if currentChunkIndex >= totalChunks - 1 {
            if isLooping {
                nextIndex = 0
            } else {
                return nil
            }
        } else {
            nextIndex = currentChunkIndex + 1
        }

        currentChunkIndex = nextIndex

        return chunks[nextIndex]
    }

    /// Peek at the next chunk without advancing
    func peekNextChunk() -> BufferedChunk? {
        let nextIndex: Int

        if currentChunkIndex >= totalChunks - 1 {
            if isLooping {
                nextIndex = 0
            } else {
                return nil
            }
        } else {
            nextIndex = currentChunkIndex + 1
        }

        return chunks[nextIndex]
    }

    /// Get which chunk indices need to be fetched
    /// - Returns: Array of chunk indices that should be downloaded/converted
    func chunksNeeded() -> [Int] {
        var needed: [Int] = []

        for offset in 0..<maxBufferAhead {
            var targetIndex = currentChunkIndex + offset

            if targetIndex >= totalChunks {
                if isLooping {
                    targetIndex = targetIndex % totalChunks
                } else {
                    break
                }
            }

            if chunks[targetIndex] == nil {
                needed.append(targetIndex)
            }
        }

        return needed
    }

    /// Check if the buffer is ready to start playback
    var isReadyToPlay: Bool {
        // Ready when we have the current chunk and at least minBufferAhead - 1 more
        guard chunks[currentChunkIndex] != nil else { return false }

        var readyCount = 1
        for offset in 1..<minBufferAhead {
            let targetIndex = (currentChunkIndex + offset) % max(totalChunks, 1)
            if chunks[targetIndex] != nil {
                readyCount += 1
            }
        }

        return readyCount >= min(minBufferAhead, totalChunks)
    }

    /// Get the buffer fill level (0.0 to 1.0)
    var bufferFillLevel: Double {
        guard totalChunks > 0 else { return 0 }
        let bufferedCount = Double(chunks.count)
        let maxBuffered = Double(min(maxBufferAhead, totalChunks))
        return min(1.0, bufferedCount / maxBuffered)
    }

    /// Seek to a specific chunk index
    func seek(toChunk index: Int) {
        guard index >= 0 && index < totalChunks else { return }
        currentChunkIndex = index
        cleanupOldChunks()
        updateBufferState()
    }

    /// Seek to a percentage of the video
    func seek(toPercentage percentage: Double) {
        let targetChunk = Int(percentage * Double(totalChunks - 1))
        seek(toChunk: max(0, min(targetChunk, totalChunks - 1)))
    }

    /// Get current playback position as percentage
    var currentPercentage: Double {
        guard totalChunks > 1 else { return 0 }
        return Double(currentChunkIndex) / Double(totalChunks - 1)
    }

    /// Current chunk index
    var currentIndex: Int {
        currentChunkIndex
    }

    /// Total number of chunks
    var chunkCount: Int {
        totalChunks
    }

    /// Whether looping is enabled
    var loopingEnabled: Bool {
        isLooping
    }

    /// Clear all buffered chunks
    func clear() {
        // Delete all chunk files
        for (_, chunk) in chunks {
            try? FileManager.default.removeItem(at: chunk.fileURL)
        }
        chunks.removeAll()
        currentChunkIndex = 0
        currentState = .empty
    }

    // MARK: - Private Methods

    private func cleanupOldChunks() {
        // Determine which chunks to keep
        let keepRange: Set<Int>

        if isLooping && totalChunks > 0 {
            // For looping, keep chunks in a window around current position
            var keep = Set<Int>()
            // Keep 2 behind and maxBufferAhead ahead
            for offset in -2..<maxBufferAhead {
                let index = (currentChunkIndex + offset + totalChunks) % totalChunks
                keep.insert(index)
            }
            keepRange = keep
        } else {
            // For non-looping, keep current and ahead
            let minKeep = max(0, currentChunkIndex - 2)
            let maxKeep = min(totalChunks - 1, currentChunkIndex + maxBufferAhead)
            keepRange = Set(minKeep...maxKeep)
        }

        // Remove chunks outside the keep range
        for (index, chunk) in chunks where !keepRange.contains(index) {
            try? FileManager.default.removeItem(at: chunk.fileURL)
            chunks.removeValue(forKey: index)
        }
    }

    private func updateBufferState() {
        if chunks.isEmpty {
            currentState = .empty
        } else if isReadyToPlay {
            currentState = .ready
        } else {
            let progress = bufferFillLevel
            currentState = .buffering(progress: progress)
        }
    }
}

// MARK: - Convenience Extensions

extension ChunkBufferManager {
    /// Create an AVPlayerItem for a buffered chunk
    nonisolated func createPlayerItem(for chunk: BufferedChunk) -> AVPlayerItem {
        let asset = AVURLAsset(url: chunk.fileURL)
        return AVPlayerItem(asset: asset)
    }

    /// Get stats about current buffer state
    func bufferStats() -> (buffered: Int, current: Int, total: Int, fillLevel: Double) {
        (chunks.count, currentChunkIndex, totalChunks, bufferFillLevel)
    }
}
