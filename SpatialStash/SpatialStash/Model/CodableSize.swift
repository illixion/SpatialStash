/*
 Spatial Stash - Codable Size

 Small Codable/Hashable wrapper around CGSize so window values can persist a
 size into visionOS scene restoration archives (CGSize itself is not Codable in
 a way that survives the scene-value encoder cleanly). Used to remember the
 user's custom window size across cold relaunches.
 */

import CoreGraphics

struct CodableSize: Codable, Hashable {
    var width: CGFloat
    var height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}
