/*
 Spatial Stash - Tab Navigation

 Defines the available tabs in the app.
 */

import Foundation

enum Tab: String, CaseIterable, Identifiable {
    case pictures = "Pictures"
    case videos = "Videos"
    case filters = "Filters"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pictures: return "photo.stack"
        case .videos: return "video"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .settings: return "gearshape"
        }
    }
}
