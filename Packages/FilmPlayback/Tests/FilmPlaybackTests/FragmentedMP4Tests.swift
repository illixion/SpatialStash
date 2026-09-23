import CoreMedia
import Foundation
import Testing
@testable import FilmPlayback

/// The fixture is the plugin's init segment for a Dolby Vision profile 8.1
/// UHD remux (The Wild Robot): a dvh1 entry with hvcC and dvvC.
@Suite struct FragmentedMP4Tests {
    let initSegment = try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/dvh1-p8-init", withExtension: "mp4")!)

    @Test func readsTheTrack() throws {
        let track = try FragmentedMP4Track(initSegment: initSegment)
        #expect(track.timescale == 16000)
        #expect(track.codecTag == "dvh1")
    }

    @Test func coreMediaKeepsTheDolbyVisionConfiguration() throws {
        let format = try FragmentedMP4Track(initSegment: initSegment).makeFormatDescription()
        #expect(FilmVideoPlayer.fourCC(CMFormatDescriptionGetMediaSubType(format)) == "dvh1")
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 3840 && dimensions.height == 1608)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        #expect(atoms["hvcC"] != nil)
        #expect(atoms["dvvC"] != nil)
    }

    @Test func findsTheSegmentForATime() {
        let index = FilmVideoIndex(segmentStarts: [0, 1.001, 2.002, 12.429], durationSeconds: 20,
                                   codec: "hevc", videoRange: "DOVIWithHDR10", dvProfile: 8, dolbyVision: true)
        #expect(index.segment(containing: 0) == 0)
        #expect(index.segment(containing: 1.5) == 1)
        #expect(index.segment(containing: 12.429) == 3)
        #expect(index.segment(containing: 19) == 3)
    }
}
