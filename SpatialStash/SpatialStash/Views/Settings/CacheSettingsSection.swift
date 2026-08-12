/*
 Spatial Stash - Cache Settings Section

 The Settings "Cache" section: a global size preset (fraction of device
 storage, split across caches by CacheBudget shares), one row per disk cache
 showing its current usage against its nominal cap with an inline Clear
 button, and totals with the volume's free space.
 */

import RAVEMedia
import SwiftUI

struct CacheSettingsSection: View {
    private struct DomainStats {
        var fileCount = 0
        var totalSize: Int64 = 0
    }

    @State private var preset: CacheSizePreset = CacheBudget.preset
    @State private var stats: [CacheBudget.Domain: DomainStats] = [:]
    @State private var clearing: Set<CacheBudget.Domain> = []
    @State private var freeSpace: Int64 = 0

    /// Display order — biggest budget shares first.
    private static let domains: [CacheBudget.Domain] = [
        .videos, .images, .depth, .autoEnhance, .backgroundRemoval,
        .gifHEVC, .thumbnails, .thumbnailDioramas
    ]

    var body: some View {
        Section {
            Picker("Cache Size", selection: $preset) {
                ForEach(CacheSizePreset.allCases) { preset in
                    Text("\(preset.label) (\(formatBytes(totalAllowance(preset))))").tag(preset)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: preset) { _, newValue in
                CacheBudget.preset = newValue
                Task {
                    await enforceAllBudgets()
                    await refresh()
                }
            }

            ForEach(Self.domains, id: \.self) { domain in
                row(for: domain)
            }

            HStack {
                Text("Total")
                    .fontWeight(.medium)
                Spacer()
                Text(formatBytes(totalUsage))
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
            }
        } header: {
            Text("Cache")
        } footer: {
            Text("Caches use up to \(formatBytes(totalAllowance(preset))) (\(Int(preset.fractionOfCapacity * 100))% of this device's storage), always leave at least \(formatBytes(CacheBudget.freeSpaceFloor)) free, and shrink automatically when the disk fills. Least-recently-used entries are removed first. Free space: \(formatBytes(freeSpace)).")
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private func row(for domain: CacheBudget.Domain) -> some View {
        let domainStats = stats[domain] ?? DomainStats()
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.label)
                Text("\(domainStats.fileCount) items · \(formatBytes(domainStats.totalSize)) of \(formatBytes(CacheBudget.nominalCap(for: domain)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if clearing.contains(domain) {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("Clear", role: .destructive) {
                    clearing.insert(domain)
                    Task {
                        await clear(domain)
                        await refresh()
                        clearing.remove(domain)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(domainStats.totalSize == 0)
            }
        }
    }

    private var totalUsage: Int64 {
        stats.values.reduce(0) { $0 + $1.totalSize }
    }

    private func totalAllowance(_ preset: CacheSizePreset) -> Int64 {
        let (capacity, _) = CacheBudget.volumeStats()
        return Int64(preset.fractionOfCapacity * Double(capacity))
    }

    private func refresh() async {
        var fresh: [CacheBudget.Domain: DomainStats] = [:]
        let image = await DiskImageCache.shared.getCacheStats()
        fresh[.images] = DomainStats(fileCount: image.fileCount, totalSize: image.totalSize)
        let video = await DiskVideoCache.shared.getCacheStats()
        fresh[.videos] = DomainStats(fileCount: video.fileCount, totalSize: video.totalSize)
        let enhance = await AutoEnhanceCache.shared.getCacheStats()
        fresh[.autoEnhance] = DomainStats(fileCount: enhance.fileCount, totalSize: enhance.totalSize)
        let removal = await BackgroundRemovalCache.shared.getCacheStats()
        fresh[.backgroundRemoval] = DomainStats(fileCount: removal.fileCount, totalSize: removal.totalSize)
        let animated = await DiskAnimatedHEVCCache.shared.getCacheStats()
        fresh[.gifHEVC] = DomainStats(fileCount: animated.fileCount, totalSize: animated.totalSize)
        let thumbs = await ThumbnailCache.shared.getCacheStats()
        fresh[.thumbnails] = DomainStats(fileCount: thumbs.fileCount, totalSize: thumbs.totalSize)
        let dioramas = ThumbnailDioramaCache.getCacheStats()
        fresh[.thumbnailDioramas] = DomainStats(fileCount: dioramas.fileCount, totalSize: dioramas.totalSize)
        let depthEntries = DepthCacheStore.allEntries()
        fresh[.depth] = DomainStats(fileCount: depthEntries.count, totalSize: DepthCacheStore.totalSize())
        stats = fresh
        freeSpace = CacheBudget.volumeStats().available
    }

    private func clear(_ domain: CacheBudget.Domain) async {
        switch domain {
        case .images:
            await ImageLoader.shared.clearMemoryCache()
            await DiskImageCache.shared.clearCache()
        case .videos:
            await DiskVideoCache.shared.clearCache()
        case .autoEnhance:
            await AutoEnhanceCache.shared.clearCache()
        case .backgroundRemoval:
            // Thumbnail dioramas derive from the same Vision pipeline output.
            await BackgroundRemovalCache.shared.clearCache()
            ThumbnailDioramaCache.shared.clearCache()
        case .gifHEVC:
            await DiskAnimatedHEVCCache.shared.clearCache()
        case .thumbnails:
            await ThumbnailCache.shared.clearCache()
        case .thumbnailDioramas:
            ThumbnailDioramaCache.shared.clearCache()
        case .depth:
            DepthCacheStore.deleteAll()
        }
    }

    /// A preset downgrade may put caches over their new caps — trim now
    /// rather than waiting for the next write.
    private func enforceAllBudgets() async {
        await DiskImageCache.shared.enforceBudget()
        await DiskVideoCache.shared.enforceBudget()
        await AutoEnhanceCache.shared.enforceBudget()
        await BackgroundRemovalCache.shared.enforceBudget()
        await DiskAnimatedHEVCCache.shared.enforceBudget()
        await ThumbnailCache.shared.enforceBudget()
        ThumbnailDioramaCache.enforceBudget()
        DepthCacheStore.enforceBudget()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
