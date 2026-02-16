/*
 Spatial Stash - Media Info Popover

 Floating popover for setting star rating and O counter on images/videos.
 Opened from viewer ornaments via a star button.
 */

import SwiftUI

struct MediaInfoPopover: View {
    let currentRating100: Int?
    let oCounter: Int
    let isUpdating: Bool
    let onRate: (Int?) -> Void
    let onIncrementO: () -> Void
    let onDecrementO: () -> Void

    private var starRating: Int {
        guard let rating100 = currentRating100 else { return 0 }
        return ImageFilterCriteria.ratingFromAPI(rating100)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Star Rating
            VStack(spacing: 8) {
                Text("Rating")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            let newRating100 = ImageFilterCriteria.ratingToAPI(star)
                            onRate(newRating100)
                        } label: {
                            Image(systemName: star <= starRating ? "star.fill" : "star")
                                .font(.title2)
                                .foregroundColor(star <= starRating ? .yellow : .gray)
                        }
                        .buttonStyle(.borderless)
                    }

                    if currentRating100 != nil {
                        Button {
                            onRate(nil)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear Rating")
                    }
                }
            }

            Divider()

            // O Counter
            VStack(spacing: 8) {
                Text("O Count")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        onDecrementO()
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(oCounter <= 0 || isUpdating)

                    if isUpdating {
                        ProgressView()
                            .frame(minWidth: 40)
                    } else {
                        Text("\(oCounter)")
                            .font(.title2.monospacedDigit())
                            .frame(minWidth: 40)
                    }

                    Button {
                        onIncrementO()
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isUpdating)
                }
            }
        }
        .padding(20)
    }
}
