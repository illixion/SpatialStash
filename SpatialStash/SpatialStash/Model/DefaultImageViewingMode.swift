/*
 Spatial Stash - Default Image Viewing Mode

 Enum mirroring the photo viewer's 3D menu options. Persisted in
 UserDefaults via AppModel and applied when opening a photo that has
 no per-image remembered viewing mode.
 */

import Foundation

enum DefaultImageViewingMode: String, CaseIterable, Identifiable {
    case mono
    case spatial3D
    case spatial3DImmersive
    case diorama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mono: return "2D"
        case .spatial3D: return "3D"
        case .spatial3DImmersive: return "Immersive 3D"
        case .diorama: return "Diorama"
        }
    }
}
