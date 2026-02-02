/*
 Spatial Stash - Spatial 3D Conversion Tracker

 Tracks which images have been converted to spatial 3D so they can be
 automatically re-converted when viewed again.
 */

import Foundation
import os

enum ViewingModePreference: String {
    case mono
    case spatial3D
}

actor Spatial3DConversionTracker {
    static let shared = Spatial3DConversionTracker()

    private let userDefaultsKey = "spatial3DConvertedImages"
    private let lastModeKey = "spatial3DLastViewingMode"
    private var convertedImageURLs: Set<String>
    private var lastViewingModeByURL: [String: String]

    private init() {
        // Load from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] {
            convertedImageURLs = Set(saved)
            let count = convertedImageURLs.count
            AppLogger.spatial3DTracker.info("Loaded \(count, privacy: .public) previously converted images")
        } else {
            convertedImageURLs = []
        }

        if let dict = UserDefaults.standard.dictionary(forKey: lastModeKey) as? [String: String] {
            lastViewingModeByURL = dict
        } else {
            lastViewingModeByURL = [:]
        }
    }

    /// Mark an image as having been converted to spatial 3D
    func markAsConverted(url: URL) {
        let urlString = url.absoluteString
        convertedImageURLs.insert(urlString)
        save()
    }

    /// Check if an image has been previously converted
    func wasConverted(url: URL) -> Bool {
        return convertedImageURLs.contains(url.absoluteString)
    }

    /// Remove conversion status for an image
    func removeConversionStatus(url: URL) {
        convertedImageURLs.remove(url.absoluteString)
        save()
    }

    /// Clear all conversion tracking data
    func clearAll() {
        convertedImageURLs.removeAll()
        lastViewingModeByURL.removeAll()
        save()
    }

    /// Get the count of tracked conversions
    var convertedCount: Int {
        convertedImageURLs.count
    }

    private func save() {
        UserDefaults.standard.set(Array(convertedImageURLs), forKey: userDefaultsKey)
        UserDefaults.standard.set(lastViewingModeByURL, forKey: lastModeKey)
    }

    // MARK: - Last Viewing Mode Tracking

    func setLastViewingMode(url: URL, mode: ViewingModePreference) {
        lastViewingModeByURL[url.absoluteString] = mode.rawValue
        save()
    }

    func lastViewingMode(url: URL) -> ViewingModePreference? {
        guard let raw = lastViewingModeByURL[url.absoluteString] else { return nil }
        return ViewingModePreference(rawValue: raw)
    }
}
