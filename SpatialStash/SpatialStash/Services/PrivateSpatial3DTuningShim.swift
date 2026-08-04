//
//  PrivateSpatial3DTuningShim.swift
//  SpatialStash
//
//  Unlike PrivateSpatial3DTuning.swift, this file is ALWAYS compiled. It gives
//  every spatial-3D presentation path a single call to make, so the call sites
//  don't each need their own #if and a new path can't silently miss the tuning.
//  In builds without SPATIALSTASH_PRIVATE_API the body is empty and the call
//  compiles away.
//

import RealityKit

extension ImagePresentationComponent {
    /// Apply the GitHub-only private spatial-3D tuning if this build has it and
    /// the user enabled it. No-op in App Store builds.
    ///
    /// Call immediately before handing the component to `components.set(_:)`,
    /// and on every viewing-mode change too: the visionOS 27 immersive
    /// presentation appears to re-assert its own values on transition, so a
    /// one-time application at creation is not enough.
    @MainActor
    mutating func applyPrivateSpatial3DTuningIfAvailable() {
        #if SPATIALSTASH_PRIVATE_API
        PrivateSpatial3DTuningStore.shared.apply(to: &self)
        #endif
    }
}
