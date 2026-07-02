/*
 Spatial Stash - Depth Model Store

 Filesystem management for the monocular depth models used by fake-3D video.

 Models live in a managed store under Application Support (`DepthModels/`), which
 is excluded from iCloud/device backup — they're large, re-downloadable assets.
 `CoreMLDepthProvider` loads from here (see DepthProvider.modelSearchDirectories).

 The app's Documents folder acts as a drop-off *inbox*: a model pushed via
 `scripts/push-depth-model.sh` (devicectl) or dropped in via the Files app is
 moved into the managed store on launch (`importInboxModels`) and removed from
 Documents. So both the in-app download (DepthModelManager) and the manual push
 converge on the same store, and both get switch/delete for free.
 */

import Foundation
import os

enum DepthModelStore {
    /// A model on disk is either a precompiled `.mlmodelc` or an `.mlpackage`.
    static let modelExtensions = ["mlmodelc", "mlpackage"]

    // MARK: Directories

    /// Managed store: `Application Support/DepthModels`, created on first use and
    /// excluded from backup (models are large and re-downloadable).
    static var modelsDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("DepthModels", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    /// Cache of compiled `.mlmodelc` products for `.mlpackage` sources (shared
    /// with `CoreMLDepthProvider.compiledModelURL`). Cleared per-model on delete.
    static var compiledCacheDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("CompiledDepthModels", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Documents folder — the drop-off inbox drained by `importInboxModels`.
    static var documentsInbox: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    // MARK: Query

    static func installedModelURLs() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { modelExtensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Base names (no extension) of installed models, e.g. `DepthAnythingV2SmallF16`.
    static func installedModelNames() -> [String] {
        installedModelURLs().map { $0.deletingPathExtension().lastPathComponent }
    }

    static func isInstalled(_ name: String) -> Bool {
        modelURL(named: name) != nil
    }

    /// Total on-disk size of an installed model (package or compiled bundle).
    static func modelSize(named name: String) -> Int64 {
        guard let url = modelURL(named: name) else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// The managed-store URL for a model base name, preferring a compiled
    /// `.mlmodelc` over an `.mlpackage` (both load; the former loads instantly).
    static func modelURL(named name: String) -> URL? {
        let fm = FileManager.default
        for ext in modelExtensions {
            let url = modelsDirectory.appendingPathComponent(name).appendingPathExtension(ext)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Mutate

    /// Move any depth models sitting in the Documents inbox into the managed
    /// store and delete them from Documents. Returns the base names imported.
    @discardableResult
    static func importInboxModels() -> [String] {
        let fm = FileManager.default
        guard let inbox = documentsInbox,
              let urls = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return [] }
        let store = modelsDirectory
        var imported: [String] = []
        for url in urls where modelExtensions.contains(url.pathExtension) {
            let dest = store.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: url, to: dest)
                imported.append(dest.deletingPathExtension().lastPathComponent)
                AppLogger.videoWindow.info("Imported depth model from Documents: \(url.lastPathComponent, privacy: .public)")
            } catch {
                AppLogger.videoWindow.error("Failed to import \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return imported
    }

    /// Remove a model (both extensions) from the managed store, plus its compiled
    /// cache so a later re-download/re-import recompiles cleanly.
    static func deleteModel(named name: String) {
        let fm = FileManager.default
        for ext in modelExtensions {
            try? fm.removeItem(at: modelsDirectory.appendingPathComponent(name).appendingPathExtension(ext))
        }
        try? fm.removeItem(at: compiledCacheDirectory.appendingPathComponent(name).appendingPathExtension("mlmodelc"))
    }
}
