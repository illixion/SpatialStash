/*
 Spatial Stash - Remote History View

 Grid overlay showing the RoboFrame server's rolling viewing history,
 fetched from /history.json and shared across all viewer windows pointed
 at the same endpoint. Sectioned per display (`groups`), mirroring the
 server's own /history page, rather than one merged list — the same post
 can legitimately appear under more than one display's section.
 */

import SwiftUI

struct RemoteHistoryView: View {
    let store: RemoteHistoryStore
    var onEntrySelected: ((RemoteHistoryEntry) -> Void)?

    /// The server's sentinel bucket for requests with no deviceId.
    private static let othersDeviceId = "others"

    var body: some View {
        ScrollView {
            if store.groups.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(store.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(label(for: group.deviceId))
                                .font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                                ForEach(group.posts) { entry in
                                    thumbnail(for: entry)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(32)
        .overlay(alignment: .topTrailing) {
            if store.isLoading {
                ProgressView()
                    .padding(16)
            }
        }
    }

    /// "others" (no deviceId attached to the request) reads better as
    /// "Other" than the server's raw bucket name; every other deviceId is
    /// shown verbatim since it's whatever string the viewing display was
    /// configured with.
    private func label(for deviceId: String) -> String {
        deviceId == Self.othersDeviceId ? "Other" : deviceId
    }

    private func thumbnail(for entry: RemoteHistoryEntry) -> some View {
        Group {
            if let url = store.imageURL(for: entry) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 120)
                            .clipped()
                            .cornerRadius(8)
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                            .overlay(ProgressView().scaleEffect(0.6))
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .onTapGesture { onEntrySelected?(entry) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.isLoading {
                ProgressView()
            } else if let error = store.lastError {
                Text("History unavailable")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No history yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.3))
            .frame(height: 120)
    }
}
