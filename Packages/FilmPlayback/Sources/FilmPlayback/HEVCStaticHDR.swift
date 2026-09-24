/*
 Hypnos - HDR static metadata from an HEVC keyframe's SEI

 The plugin's fmp4 muxer copies the stream but writes no `mdcv`/`clli`
 boxes, so the format description CoreMedia builds from the sample entry
 says PQ / BT.2020 and nothing about the mastering display. visionOS then
 composites the picture without HDR headroom. The same values ride in
 every keyframe as prefix SEI messages (mastering display colour volume,
 payload 137; content light level, payload 144), and their payloads have
 exactly the byte layout of CoreMedia's MasteringDisplayColorVolume (24
 bytes) and ContentLightLevelInfo (4 bytes) extensions. Longwave's Moonlight
 renderer sets the same two extensions, and its HDR is confirmed on device.
 */

import CoreMedia
import Foundation

enum HEVCStaticHDR {
    struct Metadata: Equatable {
        var masteringDisplay: Data?
        var contentLightLevel: Data?
        var isEmpty: Bool { masteringDisplay == nil && contentLightLevel == nil }
    }

    /// Reads the prefix SEI of one length-prefixed (4-byte) HEVC access unit.
    static func metadata(in accessUnit: Data) -> Metadata {
        var result = Metadata()
        let bytes = [UInt8](accessUnit)
        var p = 0
        while p + 4 <= bytes.count {
            let length = Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            let start = p + 4
            guard length > 2, start + length <= bytes.count else { break }
            let type = (bytes[start] >> 1) & 0x3F
            if type == 39 { // PREFIX_SEI_NUT
                parseSEI(unescape(bytes[(start + 2) ..< (start + length)]), into: &result)
            }
            p = start + length
        }
        return result
    }

    /// `format` with the metadata added, or `format` itself when there is nothing to add.
    static func applying(_ metadata: Metadata, to format: CMVideoFormatDescription) -> CMVideoFormatDescription {
        guard !metadata.isEmpty else { return format }
        var extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if let mdcv = metadata.masteringDisplay,
           extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] == nil {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] = mdcv
        }
        if let clli = metadata.contentLightLevel,
           extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] == nil {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = clli
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        var updated: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: CMFormatDescriptionGetMediaSubType(format),
            width: dimensions.width, height: dimensions.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &updated
        ) == noErr, let updated else { return format }
        return updated
    }

    /// Removes emulation-prevention bytes (00 00 03 → 00 00).
    private static func unescape(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    private static func parseSEI(_ rbsp: [UInt8], into result: inout Metadata) {
        var p = 0
        // Each message: payload type and size as 0xFF-extended bytes, then the payload.
        while p < rbsp.count, rbsp[p] != 0x80 { // 0x80: rbsp trailing bits
            var type = 0
            while p < rbsp.count, rbsp[p] == 0xFF { type += 255; p += 1 }
            guard p < rbsp.count else { return }
            type += Int(rbsp[p]); p += 1
            var size = 0
            while p < rbsp.count, rbsp[p] == 0xFF { size += 255; p += 1 }
            guard p < rbsp.count else { return }
            size += Int(rbsp[p]); p += 1
            guard p + size <= rbsp.count else { return }
            let payload = Data(rbsp[p ..< p + size])
            switch (type, size) {
            case (137, 24): result.masteringDisplay = payload
            case (144, 4): result.contentLightLevel = payload
            default: break
            }
            p += size
        }
    }
}
