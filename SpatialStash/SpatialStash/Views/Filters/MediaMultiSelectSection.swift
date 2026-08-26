/*
 Spatial Stash - Media Multi-Select Filter Section

 One multi-select filter dimension: selected values as chips, an operator, and a
 searchable list of what else can be picked.

 Written once for albums and people rather than per dimension. The Stash filters
 next door are four near-identical copies of this interaction (galleries, tags,
 studios, performers) that have already drifted apart in small ways, and the
 photo-library side is not going to add two more.

 Chips carry a thumbnail when the dimension can supply one — an album shows its
 first photo, and a person will show their face once there is a source for faces.
 A name alone is a poor way to recognise either.
 */

import Photos
import SwiftUI
import UIKit

/// One pickable value, flattened from whatever the dimension's own model is so
/// this view stays non-generic.
struct FilterOption: Identifiable, Hashable {
    let id: String
    let name: String
    /// Trailing detail, typically a count.
    let detail: String?
    /// A Photos local identifier to draw a thumbnail from, when there is one.
    let thumbnailAssetId: String?
    /// Sorted after the primary group and separated from it — user albums come
    /// before the system's smart albums.
    let isSecondary: Bool

    init(id: String,
         name: String,
         detail: String? = nil,
         thumbnailAssetId: String? = nil,
         isSecondary: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.thumbnailAssetId = thumbnailAssetId
        self.isSecondary = isSecondary
    }
}

struct MediaMultiSelectSection: View {
    let title: String
    var footer: String?
    var emptyMessage: String = "Nothing to choose from."
    let options: [FilterOption]
    var isLoading: Bool = false
    @Binding var selection: [AutocompleteItem]
    @Binding var modifier: CriterionModifier

    /// Above this many options the list gets a filter field of its own.
    private static let searchThreshold = 8

    @State private var query = ""

    private var filteredOptions: [FilterOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var thumbnailsById: [String: String] {
        Dictionary(options.compactMap { option in
            option.thumbnailAssetId.map { (option.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        Section {
            if !selection.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(selection) { item in
                        MediaFilterChip(name: item.name,
                                        thumbnailAssetId: thumbnailsById[item.id]) {
                            selection.removeAll { $0.id == item.id }
                        }
                    }
                }
                .padding(.vertical, 4)

                // Only meaningful with more than one value: "any of" and "all of"
                // describe the same set when there is a single member.
                if selection.count > 1 {
                    Picker("Match", selection: $modifier) {
                        ForEach(CriterionModifier.multiModifiers) { option in
                            Text(matchLabel(for: option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
            } else if options.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                if options.count > Self.searchThreshold {
                    TextField("Filter this list...", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }

                ForEach(filteredOptions) { option in
                    optionRow(option)
                }

                if filteredOptions.isEmpty {
                    Text("No matches.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: FilterOption) -> some View {
        let isSelected = selection.contains { $0.id == option.id }
        Button {
            if isSelected {
                selection.removeAll { $0.id == option.id }
            } else {
                selection.append(AutocompleteItem(id: option.id, name: option.name))
            }
        } label: {
            HStack(spacing: 12) {
                MediaFilterThumbnail(assetId: option.thumbnailAssetId, side: 32)
                Text(option.name)
                    .foregroundStyle(option.isSecondary ? .secondary : .primary)
                Spacer()
                if let detail = option.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The operators, named for what they mean here rather than in Stash's
    /// vocabulary — "includes all" is accurate and unreadable.
    private func matchLabel(for modifier: CriterionModifier) -> String {
        switch modifier {
        case .includesAll: return "All of"
        case .includes: return "Any of"
        case .excludes: return "None of"
        default: return modifier.displayName
        }
    }
}

// MARK: - Chip

struct MediaFilterChip: View {
    let name: String
    var thumbnailAssetId: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MediaFilterThumbnail(assetId: thumbnailAssetId, side: 28)
            Text(name)
                .font(.body)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.2))
        .cornerRadius(12)
    }
}

// MARK: - Thumbnail

/// A small square thumbnail for a Photos asset, or nothing at all.
///
/// Renders as a zero-size view when there is no asset to show, so a dimension
/// with no thumbnails lays out exactly as it would without them.
struct MediaFilterThumbnail: View {
    let assetId: String?
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let assetId {
                thumbnail
                    .task(id: assetId) { await load(assetId) }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func load(_ assetId: String) async {
        guard image == nil,
              let url = PhotosAssetURL.url(forLocalIdentifier: assetId) else { return }
        image = await PhotosAssetStore.shared.thumbnail(for: url, maxSize: side * 3)
    }
}
