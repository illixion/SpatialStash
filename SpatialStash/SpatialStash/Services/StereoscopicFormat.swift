/*
 Spatial Stash - Stereoscopic Format Detection

 Enum and utilities for detecting and handling stereoscopic 3D video formats.
 */

import Foundation

/// Stereoscopic video format types
enum StereoscopicFormat: String, CaseIterable, Codable {
    case sideBySide = "sbs"          // Side-by-side (left|right) - full width per eye
    case overUnder = "ou"            // Over-under (top/bottom) - full height per eye
    case halfSideBySide = "hsbs"     // Half-width SBS (squeezed horizontally)
    case halfOverUnder = "hou"       // Half-height OU (squeezed vertically)

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .sideBySide: return "Side-by-Side"
        case .overUnder: return "Over-Under"
        case .halfSideBySide: return "Half SBS"
        case .halfOverUnder: return "Half OU"
        }
    }

    /// Short label for UI badges
    var shortLabel: String {
        rawValue.uppercased()
    }

    /// Whether the source has half resolution per eye (squeezed format)
    var isHalfResolution: Bool {
        switch self {
        case .halfSideBySide, .halfOverUnder:
            return true
        case .sideBySide, .overUnder:
            return false
        }
    }

    /// Whether the format splits horizontally (SBS variants)
    var isHorizontalSplit: Bool {
        switch self {
        case .sideBySide, .halfSideBySide:
            return true
        case .overUnder, .halfOverUnder:
            return false
        }
    }

    /// Calculate per-eye dimensions from source dimensions
    func perEyeDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        switch self {
        case .sideBySide:
            // Full SBS: each eye is half the width, full height
            return (sourceWidth / 2, sourceHeight)
        case .halfSideBySide:
            // Half SBS: already squeezed, so per-eye is half width (needs horizontal stretch)
            return (sourceWidth / 2, sourceHeight)
        case .overUnder:
            // Full OU: each eye is full width, half height
            return (sourceWidth, sourceHeight / 2)
        case .halfOverUnder:
            // Half OU: already squeezed, so per-eye is half height (needs vertical stretch)
            return (sourceWidth, sourceHeight / 2)
        }
    }
}

// MARK: - Tag Detection

extension StereoscopicFormat {

    /// Tag names that indicate stereoscopic content (case-insensitive)
    static let stereoscopicTagNames: Set<String> = [
        "stereoscopic", "3d", "vr", "stereogram",
        "sbs", "side-by-side", "sidebyside", "side by side",
        "ou", "over-under", "overunder", "over under", "tab", "top-and-bottom",
        "hsbs", "half-sbs", "half sbs",
        "hou", "half-ou", "half ou"
    ]

    /// Detect stereoscopic format from an array of tag names
    /// - Parameter tagNames: Array of tag names from Stash
    /// - Returns: Tuple indicating if video is stereoscopic and the detected format
    static func detect(from tagNames: [String]) -> (isStereoscopic: Bool, format: StereoscopicFormat?) {
        let lowerTags = tagNames.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        // Check if any stereoscopic indicator tag is present
        let hasStereoscopicTag = lowerTags.contains { tag in
            stereoscopicTagNames.contains(tag)
        }

        guard hasStereoscopicTag else {
            return (false, nil)
        }

        // Try to determine specific format from tags
        // Check half-resolution formats first (more specific)
        if lowerTags.contains(where: { $0.contains("hsbs") || $0.contains("half-sbs") || $0.contains("half sbs") }) {
            return (true, .halfSideBySide)
        }

        if lowerTags.contains(where: { $0.contains("hou") || $0.contains("half-ou") || $0.contains("half ou") }) {
            return (true, .halfOverUnder)
        }

        // Check full-resolution formats
        if lowerTags.contains(where: { tag in
            tag.contains("sbs") || tag.contains("side-by-side") || tag.contains("sidebyside") || tag.contains("side by side")
        }) {
            return (true, .sideBySide)
        }

        if lowerTags.contains(where: { tag in
            tag.contains("ou") || tag.contains("over-under") || tag.contains("overunder") ||
            tag.contains("over under") || tag.contains("tab") || tag.contains("top-and-bottom")
        }) {
            return (true, .overUnder)
        }

        // Has stereoscopic/3d/vr tag but no specific format - default to SBS
        return (true, .sideBySide)
    }
}
