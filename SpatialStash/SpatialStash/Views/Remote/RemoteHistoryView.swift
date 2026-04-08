/*
 Spatial Stash - Remote History View

 Grid overlay showing previously viewed posts in the current session.
 */

import SwiftUI

struct RemoteHistoryView: View {
    let history: [RemotePost]
    let imageURLs: [Int: URL]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(history.reversed()) { post in
                    if let url = imageURLs[post._id] {
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
            }
            .padding()
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(32)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.3))
            .frame(height: 120)
    }
}
