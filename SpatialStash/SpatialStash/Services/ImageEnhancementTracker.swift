/*
 Spatial Stash - Image Enhancement Tracker

 Tracks per-image viewing enhancements (spatial 3D conversion, background
 removal) so they can be automatically restored when the image is viewed again.
 */

import Foundation
import os

enum ViewingModePreference: String {
    case mono
    case spatial3D
    case spatial3DImmersive
    case backgroundRemoved
}

actor ImageEnhancementTracker {
    static let shared = ImageEnhancementTracker()

    // UserDefaults keys unchanged for backward compatibility
    private let userDefaultsKey = "spatial3DConvertedImages"
    private let lastModeKey = "spatial3DLastViewingMode"
    private let flippedKey = "imageFlippedState"
    private var convertedImageURLs: Set<String>
    private var lastViewingModeByURL: [String: String]
    private var flippedByURL: Set<String>

    private init() {
        if let saved = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] {
            convertedImageURLs = Set(saved)
            let count = convertedImageURLs.count
            AppLogger.enhancementTracker.info("Loaded \(count, privacy: .public) previously converted images")
        } else {
            convertedImageURLs = []
        }

        if let dict = UserDefaults.standard.dictionary(forKey: lastModeKey) as? [String: String] {
            lastViewingModeByURL = dict
        } else {
            lastViewingModeByURL = [:]
        }

        if let saved = UserDefaults.standard.array(forKey: flippedKey) as? [String] {
            flippedByURL = Set(saved)
        } else {
            flippedByURL = []
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
        flippedByURL.removeAll()
        save()
    }

    /// Get the count of tracked conversions
    var convertedCount: Int {
        convertedImageURLs.count
    }

    private func save() {
        UserDefaults.standard.set(Array(convertedImageURLs), forKey: userDefaultsKey)
        UserDefaults.standard.set(lastViewingModeByURL, forKey: lastModeKey)
        UserDefaults.standard.set(Array(flippedByURL), forKey: flippedKey)
    }

    // MARK: - Backup Export / Import

    /// Export all tracking data for backup
    func exportData() -> (convertedURLs: [String], lastViewingModes: [String: String], flippedURLs: [String]) {
        return (Array(convertedImageURLs), lastViewingModeByURL, Array(flippedByURL))
    }

    /// Import tracking data from backup, replacing current data
    func importData(convertedURLs: [String], lastViewingModes: [String: String], flippedURLs: [String]? = nil) {
        convertedImageURLs = Set(convertedURLs)
        lastViewingModeByURL = lastViewingModes
        if let flippedURLs {
            flippedByURL = Set(flippedURLs)
        }
        save()
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

    // MARK: - Flip State Tracking

    func setFlipped(url: URL, isFlipped: Bool) {
        let urlString = url.absoluteString
        if isFlipped {
            flippedByURL.insert(urlString)
        } else {
            flippedByURL.remove(urlString)
        }
        save()
    }

    func isFlipped(url: URL) -> Bool {
        flippedByURL.contains(url.absoluteString)
    }
}
