/*
 Spatial Stash - Remote History View

 Grid overlay showing the RoboFrame server's rolling viewing history,
 fetched from /history.json and shared across all viewer windows pointed
 at the same endpoint.
 */

import SwiftUI

struct RemoteHistoryView: View {
    let store: RemoteHistoryStore
    var onEntrySelected: ((RemoteHistoryEntry) -> Void)?

    var body: some View {
        ScrollView {
            if store.entries.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(store.entries) { entry in
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
