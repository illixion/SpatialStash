/*
 Spatial Stash - Thumbnail Style

 Rendering style for gallery thumbnails. Persisted in UserDefaults via
 AppModel; forced to `.flat` at use sites when Reduce Motion is on.
 */

import Foundation

enum ThumbnailStyle: String, CaseIterable, Identifiable {
    case flat
    case diorama
    case spatial3D

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .diorama: return "Diorama"
        case .spatial3D: return "Spatial 3D"
        }
    }
}
