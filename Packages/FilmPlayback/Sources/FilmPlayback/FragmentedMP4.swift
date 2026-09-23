/*
 Hypnos - fragmented MP4, as the Atmos Objects plugin serves video

 Just enough ISO BMFF to turn the plugin's init and media segments into
 sample buffers: the init segment's first track (timescale, sample entry,
 trex defaults) and each media segment's samples (decode and presentation
 time, duration, sync flag, byte range). The plugin writes one track per
 file with `default-base-is-moof`, which is all this handles.

 The sample entry is kept whole. CoreMedia builds a format description
 straight from it (`kCMImageDescriptionFlavor_ISOFamily`), carrying over
 hvcC, the Dolby Vision configuration (dvcC/dvvC), colr, mdcv and clli
 without this code having to know any of them.
 */

import CoreMedia
import Foundation

public enum FragmentedMP4Error: Error, LocalizedError {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): "Malformed MP4: \(detail)"
        }
    }
}

/// The init segment's video track.
public struct FragmentedMP4Track: Sendable {
    public let timescale: Int32
    /// The whole first stsd entry (size, type, body), e.g. a `dvh1` box.
    public let sampleEntry: Data
    public let defaultSampleDuration: UInt32
    public let defaultSampleSize: UInt32
    public let defaultSampleFlags: UInt32

    /// The entry's four-character code: dvh1, dvhe, hvc1, hev1, avc1…
    public var codecTag: String {
        guard sampleEntry.count >= 8 else { return "" }
        return String(decoding: sampleEntry[sampleEntry.startIndex + 4 ..< sampleEntry.startIndex + 8], as: UTF8.self)
    }

    public init(initSegment data: Data) throws {
        let bytes = [UInt8](data)
        guard let moov = MP4Box.first("moov", in: bytes, 0 ..< bytes.count),
              let trak = MP4Box.first("trak", in: bytes, moov.body),
              let mdia = MP4Box.first("mdia", in: bytes, trak.body),
              let mdhd = MP4Box.first("mdhd", in: bytes, mdia.body),
              let minf = MP4Box.first("minf", in: bytes, mdia.body),
              let stbl = MP4Box.first("stbl", in: bytes, minf.body),
              let stsd = MP4Box.first("stsd", in: bytes, stbl.body)
        else { throw FragmentedMP4Error.malformed("init segment has no video track") }

        let version = bytes[mdhd.body.lowerBound]
        timescale = Int32(bitPattern: MP4Box.u32(bytes, mdhd.body.lowerBound + (version == 1 ? 20 : 12)))

        // stsd: version/flags (4), entry count (4), then the entries.
        let entryStart = stsd.body.lowerBound + 8
        guard let entry = MP4Box.boxes(in: bytes, entryStart ..< stsd.body.upperBound).first else {
            throw FragmentedMP4Error.malformed("stsd has no entry")
        }
        sampleEntry = Data(bytes[entry.range])

        var duration: UInt32 = 0, size: UInt32 = 0, flags: UInt32 = 0
        if let mvex = MP4Box.first("mvex", in: bytes, moov.body),
           let trex = MP4Box.first("trex", in: bytes, mvex.body) {
            // version/flags, track_ID, default_sample_description_index, then the three defaults.
            duration = MP4Box.u32(bytes, trex.body.lowerBound + 12)
            size = MP4Box.u32(bytes, trex.body.lowerBound + 16)
            flags = MP4Box.u32(bytes, trex.body.lowerBound + 20)
        }
        defaultSampleDuration = duration
        defaultSampleSize = size
        defaultSampleFlags = flags
    }

    /// A format description built from the sample entry as-is.
    public func makeFormatDescription() throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = sampleEntry.withUnsafeBytes { raw in
            CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianImageDescriptionData: raw.bindMemory(to: UInt8.self).baseAddress!,
                size: sampleEntry.count,
                stringEncoding: CFStringBuiltInEncodings.UTF8.rawValue,
                flavor: .isoFamily,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw FragmentedMP4Error.malformed("CoreMedia rejected the \(codecTag) sample entry (OSStatus \(status))")
        }
        return description
    }
}

/// One media segment's samples, in decode order.
public struct FragmentedMP4Segment: Sendable {
    public struct Sample: Sendable {
        /// Decode and presentation time, in track timescale units.
        public let decodeTime: Int64
        public let presentationTime: Int64
        public let duration: Int64
        public let isSync: Bool
        /// Byte range of the sample within the segment data.
        public let range: Range<Int>
    }

    public let data: Data
    public let samples: [Sample]

    /// First presentation time in the segment (earliest, not first in decode order).
    public var earliestPresentationTime: Int64? { samples.map(\.presentationTime).min() }
    /// Decode time just after the last sample.
    public var endDecodeTime: Int64? { samples.last.map { $0.decodeTime + $0.duration } }

    public init(data: Data, track: FragmentedMP4Track) throws {
        self.data = data
        let bytes = [UInt8](data)
        var samples: [Sample] = []
        for moof in MP4Box.boxes(in: bytes, 0 ..< bytes.count) where moof.type == "moof" {
            for traf in MP4Box.boxes(in: bytes, moof.body) where traf.type == "traf" {
                samples += try Self.samples(of: traf, moofStart: moof.range.lowerBound, bytes: bytes, track: track)
            }
        }
        guard !samples.isEmpty else { throw FragmentedMP4Error.malformed("segment has no samples") }
        self.samples = samples
    }

    private static func samples(of traf: MP4Box, moofStart: Int, bytes: [UInt8], track: FragmentedMP4Track) throws -> [Sample] {
        guard let tfhd = MP4Box.first("tfhd", in: bytes, traf.body) else {
            throw FragmentedMP4Error.malformed("traf without tfhd")
        }
        let tfhdFlags = MP4Box.u32(bytes, tfhd.body.lowerBound) & 0xFFFFFF
        var p = tfhd.body.lowerBound + 8 // version/flags, track_ID
        var base = moofStart
        if tfhdFlags & 0x1 != 0 { base = Int(MP4Box.u64(bytes, p)); p += 8 }
        if tfhdFlags & 0x2 != 0 { p += 4 } // sample description index
        var defaultDuration = track.defaultSampleDuration
        var defaultSize = track.defaultSampleSize
        var defaultFlags = track.defaultSampleFlags
        if tfhdFlags & 0x8 != 0 { defaultDuration = MP4Box.u32(bytes, p); p += 4 }
        if tfhdFlags & 0x10 != 0 { defaultSize = MP4Box.u32(bytes, p); p += 4 }
        if tfhdFlags & 0x20 != 0 { defaultFlags = MP4Box.u32(bytes, p) }

        var decodeTime: Int64 = 0
        if let tfdt = MP4Box.first("tfdt", in: bytes, traf.body) {
            decodeTime = bytes[tfdt.body.lowerBound] == 1
                ? Int64(bitPattern: MP4Box.u64(bytes, tfdt.body.lowerBound + 4))
                : Int64(MP4Box.u32(bytes, tfdt.body.lowerBound + 4))
        }

        var result: [Sample] = []
        for trun in MP4Box.boxes(in: bytes, traf.body) where trun.type == "trun" {
            let flags = MP4Box.u32(bytes, trun.body.lowerBound) & 0xFFFFFF
            let version = bytes[trun.body.lowerBound]
            let count = Int(MP4Box.u32(bytes, trun.body.lowerBound + 4))
            var q = trun.body.lowerBound + 8
            var offset = base
            if flags & 0x1 != 0 { offset = base + Int(Int32(bitPattern: MP4Box.u32(bytes, q))); q += 4 }
            var firstFlags: UInt32?
            if flags & 0x4 != 0 { firstFlags = MP4Box.u32(bytes, q); q += 4 }
            for index in 0 ..< count {
                var duration = defaultDuration, size = defaultSize, sampleFlags = defaultFlags
                var compositionOffset: Int64 = 0
                if flags & 0x100 != 0 { duration = MP4Box.u32(bytes, q); q += 4 }
                if flags & 0x200 != 0 { size = MP4Box.u32(bytes, q); q += 4 }
                if flags & 0x400 != 0 { sampleFlags = MP4Box.u32(bytes, q); q += 4 }
                if flags & 0x800 != 0 {
                    let raw = MP4Box.u32(bytes, q)
                    compositionOffset = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
                    q += 4
                }
                if index == 0, let firstFlags { sampleFlags = firstFlags }
                let end = offset + Int(size)
                guard end <= bytes.count else { throw FragmentedMP4Error.malformed("sample data past the end of the segment") }
                result.append(Sample(
                    decodeTime: decodeTime,
                    presentationTime: decodeTime + compositionOffset,
                    duration: Int64(duration),
                    isSync: sampleFlags & 0x0001_0000 == 0, // sample_is_non_sync_sample
                    range: offset ..< end
                ))
                decodeTime += Int64(duration)
                offset = end
            }
        }
        return result
    }
}

/// An ISO BMFF box: its whole byte range and its body.
struct MP4Box {
    let type: String
    let range: Range<Int>
    let body: Range<Int>

    static func boxes(in bytes: [UInt8], _ range: Range<Int>) -> [MP4Box] {
        var result: [MP4Box] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            var size = Int(u32(bytes, p))
            var header = 8
            if size == 1 {
                size = Int(u64(bytes, p + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - p
            }
            guard size >= header, p + size <= range.upperBound else { break }
            let type = String(decoding: bytes[p + 4 ..< p + 8], as: UTF8.self)
            result.append(MP4Box(type: type, range: p ..< p + size, body: p + header ..< p + size))
            p += size
        }
        return result
    }

    static func first(_ type: String, in bytes: [UInt8], _ range: Range<Int>) -> MP4Box? {
        boxes(in: bytes, range).first { $0.type == type }
    }

    static func u32(_ bytes: [UInt8], _ p: Int) -> UInt32 {
        UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
    }

    static func u64(_ bytes: [UInt8], _ p: Int) -> UInt64 {
        UInt64(u32(bytes, p)) << 32 | UInt64(u32(bytes, p + 4))
    }
}
