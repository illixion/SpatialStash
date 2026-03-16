/*
 Spatial Stash - Tab Navigation

 Defines the available tabs in the app.
 */

import Foundation

enum Tab: String, CaseIterable, Identifiable {
    case pictures = "Pictures"
    case videos = "Videos"
    case local = "Local"
    case filters = "Filters"
    case settings = "Settings"
    case console = "Console"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pictures: return "photo.stack"
        case .videos: return "video"
        case .local: return "folder"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .settings: return "gearshape"
        case .console: return "apple.terminal"
        }
    }
}
