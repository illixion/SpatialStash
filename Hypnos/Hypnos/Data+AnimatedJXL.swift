/*
 Hypnos - Animated JXL detection

 ImageIO decodes JPEG XL but reports a frame count of 1 even for animated
 files, so `CGImageSourceGetCount` cannot distinguish an animation the way it
 does for GIF. This reads the `have_animation` flag straight out of the JXL
 codestream header instead — a few dozen bits, no full decode.

 The codestream is bit-packed LSB-first. The field order mirrors libjxl's
 SizeHeader::VisitFields and ImageMetadata::VisitFields; only the fields
 preceding `have_animation` are parsed, and any nested SizeHeader/PreviewHeader
 that can appear before it is skipped in full.
*/

import Foundation

extension Data {
    /// True if this is a JPEG XL codestream whose header sets `have_animation`.
    /// Returns false for stills, non-JXL data, or anything it can't parse.
    var isAnimatedJXL: Bool {
        guard let codestream = JXLBitReader.locateCodestream(in: self) else { return false }
        var reader = JXLBitReader(codestream)
        // Signature (0xFF 0x0A) is the first two bytes; SizeHeader is byte
        // aligned right after it.
        guard reader.skipSignatureAndSizeHeader() else { return false }
        return reader.readHasAnimation()
    }
}

private struct JXLBitReader {
    private let bytes: [UInt8]
    private var bitPos = 0
    private var ok = true

    init(_ b: [UInt8]) { bytes = b }

    // MARK: codestream location

    /// Returns the JXL codestream bytes from either a bare codestream or an
    /// ISOBMFF-wrapped JXL container. A container splits the codestream across
    /// one `jxlc` box (whole) or several `jxlp` boxes (each prefixed by a
    /// 4-byte sequence index) — the fragments must be concatenated, since the
    /// first `jxlp` is often only a handful of bytes, far too short to reach the
    /// `have_animation` bit. Real encoders (and Stash-served files) use the
    /// split `jxlp` form, so reading only the first fragment misdetects animated
    /// container JXL as still.
    static func locateCodestream(in data: Data) -> [UInt8]? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }

        // Bare codestream.
        if b[0] == 0xFF && b[1] == 0x0A { return b }

        // Container: 00 00 00 0C 'JXL ' 0D 0A 87 0A, then boxes.
        let containerSig: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        guard b.count >= 12, Array(b[0..<12]) == containerSig else { return nil }

        var codestream: [UInt8] = []
        var off = 12
        while off + 8 <= b.count {
            let size32 = UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3])
            let type = Array(b[(off + 4)..<(off + 8)])
            var header = 8
            var boxSize = Int(size32)
            if size32 == 1 {
                // 64-bit largesize. Only the low bits can matter here.
                guard off + 16 <= b.count else { return nil }
                var large = 0
                for i in 0..<8 { large = (large << 8) | Int(b[off + 8 + i]) }
                boxSize = large
                header = 16
            } else if size32 == 0 {
                boxSize = b.count - off
            }
            guard boxSize >= header, off + boxSize <= b.count else { break }

            let payloadStart = off + header
            let payloadEnd = off + boxSize
            if type == [0x6A, 0x78, 0x6C, 0x63] {  // 'jxlc' — whole codestream
                codestream.append(contentsOf: b[payloadStart..<payloadEnd])
                break
            }
            if type == [0x6A, 0x78, 0x6C, 0x70] {  // 'jxlp' — 4-byte index, then a fragment
                let fragStart = payloadStart + 4
                if fragStart <= payloadEnd {
                    codestream.append(contentsOf: b[fragStart..<payloadEnd])
                }
                // Enough header bytes accumulated to reach have_animation? Stop
                // early — no need to read a multi-MB tail fragment.
                if codestream.count >= 64 { break }
            }
            off += boxSize
        }
        return codestream.isEmpty ? nil : codestream
    }

    // MARK: bit primitives (LSB-first)

    private mutating func bits(_ n: Int) -> UInt32 {
        var result: UInt32 = 0
        var i = 0
        while i < n {
            let byteIdx = bitPos >> 3
            if byteIdx >= bytes.count { ok = false; return result }
            let bit = (bytes[byteIdx] >> UInt8(bitPos & 7)) & 1
            result |= UInt32(bit) << UInt32(i)
            bitPos += 1
            i += 1
        }
        return result
    }

    private mutating func bool() -> Bool { bits(1) == 1 }

    /// U32 distribution entry: either a literal value (0 bits) or read-n-bits + offset.
    private enum Dist { case val(UInt32); case bitsOffset(Int, UInt32) }

    private mutating func u32(_ d0: Dist, _ d1: Dist, _ d2: Dist, _ d3: Dist) -> UInt32 {
        let sel = Int(bits(2))
        let d = [d0, d1, d2, d3][sel]
        switch d {
        case .val(let v): return v
        case .bitsOffset(let n, let off): return bits(n) &+ off
        }
    }

    // MARK: header fields

    private mutating func skipSizeHeader() {
        let small = bool()
        if small {
            _ = bits(5)  // ysize_div8_minus_1
        } else {
            _ = u32(.bitsOffset(9, 1), .bitsOffset(13, 1), .bitsOffset(18, 1), .bitsOffset(30, 1))  // ysize
        }
        let ratio = bits(3)
        if ratio == 0 && small {
            _ = bits(5)  // xsize_div8_minus_1
        } else if ratio == 0 && !small {
            _ = u32(.bitsOffset(9, 1), .bitsOffset(13, 1), .bitsOffset(18, 1), .bitsOffset(30, 1))  // xsize
        }
    }

    private mutating func skipPreviewHeader() {
        let div8 = bool()
        if div8 {
            _ = u32(.val(16), .val(32), .bitsOffset(5, 1), .bitsOffset(9, 33))
        } else {
            _ = u32(.bitsOffset(6, 1), .bitsOffset(8, 65), .bitsOffset(10, 321), .bitsOffset(12, 1345))
        }
        let ratio = bits(3)
        if ratio == 0 && div8 {
            _ = u32(.val(16), .val(32), .bitsOffset(5, 1), .bitsOffset(9, 33))
        } else if ratio == 0 && !div8 {
            _ = u32(.bitsOffset(6, 1), .bitsOffset(8, 65), .bitsOffset(10, 321), .bitsOffset(12, 1345))
        }
    }

    mutating func skipSignatureAndSizeHeader() -> Bool {
        // The codestream signature (0xFF 0x0A) prefixes a bare stream and the
        // fragments inside jxlp boxes; a jxlc box may omit it. Skip it when
        // present (byte aligned), otherwise the SizeHeader starts at byte 0.
        guard bytes.count >= 2 else { return false }
        bitPos = (bytes[0] == 0xFF && bytes[1] == 0x0A) ? 16 : 0
        skipSizeHeader()
        return ok
    }

    /// Parses ImageMetadata up to and including `have_animation`.
    mutating func readHasAnimation() -> Bool {
        let allDefault = bool()
        if allDefault { return false }  // defaults imply no animation
        let extraFields = bool()
        if !extraFields { return false }
        _ = bits(3)  // orientation
        if bool() { skipSizeHeader() }     // have_intrinsic_size
        if bool() { skipPreviewHeader() }  // have_preview
        let haveAnimation = bool()
        return ok && haveAnimation
    }
}
