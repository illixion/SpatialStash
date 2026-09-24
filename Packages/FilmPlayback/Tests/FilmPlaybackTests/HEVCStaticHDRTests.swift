import CoreMedia
import Foundation
import Testing
@testable import FilmPlayback

/// The fixture is the prefix SEI of a keyframe from The Wild Robot's plugin
/// segments (length-prefixed NAL units), which carries the HDR10 mastering
/// display and content light level the init segment lacks.
@Suite struct HEVCStaticHDRTests {
    let sei = try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/hevc-prefix-sei", withExtension: "bin")!)
    let initSegment = try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/dvh1-p8-init", withExtension: "mp4")!)

    @Test func readsTheStaticMetadata() throws {
        let metadata = HEVCStaticHDR.metadata(in: sei)
        let mdcv = try #require(metadata.masteringDisplay)
        let clli = try #require(metadata.contentLightLevel)
        #expect(mdcv.count == 24 && clli.count == 4)
        // Max mastering luminance is in 0.0001 cd/m²: a UHD master is 1000 or 4000 nits.
        let maxLuminance = mdcv[16 ..< 20].reduce(0) { $0 << 8 | UInt32($1) }
        #expect([1000, 4000].contains(maxLuminance / 10000))
    }

    @Test func addsItToTheFormatAndKeepsDolbyVision() throws {
        let format = try FragmentedMP4Track(initSegment: initSegment).makeFormatDescription()
        let updated = HEVCStaticHDR.applying(HEVCStaticHDR.metadata(in: sei), to: format)
        let extensions = CMFormatDescriptionGetExtensions(updated) as? [String: Any] ?? [:]
        #expect(extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil)
        #expect(extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil)
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        #expect(atoms["dvvC"] != nil && atoms["hvcC"] != nil)
        #expect(FilmVideoPlayer.fourCC(CMFormatDescriptionGetMediaSubType(updated)) == "dvh1")
    }
}
