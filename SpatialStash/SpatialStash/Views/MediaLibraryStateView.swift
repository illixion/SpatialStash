/*
 Spatial Stash - Media Library State Views

 The screens shown in place of a grid when there is nothing to draw, shared by
 the Pictures and Videos tabs so both read as one family.

 Three photo-library states need saying out loud, and which of them carries an
 action is the whole point:

   * Undecided — offers the prompt, because the user has not been asked yet.
   * Denied or restricted — sends them to Settings, the only place it can change.
   * Readable but empty — NO action, because there is nothing to fix. A
     `.limited` grant with nothing selected is a legitimate choice, not a
     failure, and offering a button there implies the user did something wrong.

 A fourth state is not about permission at all: readable, non-empty, but the
 active filter matches nothing. That one *does* carry an action, because the
 cause is something the user set and can unset — and without it a filtered-out
 library is indistinguishable from an empty one, which reads as the app having
 lost the photos.
 */

import Photos
import SwiftUI
import UIKit

/// The shared shape. Every state below is this with different words, which is
/// what keeps them recognisable as the same kind of message.
struct MediaLibraryMessageView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Explains the photo library's current state for one media kind.
struct PhotoLibraryStateView: View {
    enum MediaKind {
        case photos
        case videos

        var noun: String { self == .photos ? "photos" : "videos" }
        var emptyIcon: String { self == .photos ? "photo.on.rectangle.angled" : "video.slash" }
    }

    let kind: MediaKind
    let status: PHAuthorizationStatus
    /// Whether a photo-library filter is narrowing the results.
    var filterActive: Bool = false
    var onClearFilters: (() -> Void)?
    let onRequestAccess: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        switch status {
        case .notDetermined:
            MediaLibraryMessageView(
                icon: "photo.on.rectangle.angled",
                title: "Show Your \(kind == .photos ? "Photos" : "Videos")?",
                message: "Spatial Stash can browse the \(kind.noun) on this device and convert them to 3D. Your library is read on this device only — nothing is uploaded.",
                actionTitle: "Allow Access to Photos",
                action: onRequestAccess
            )
        case .denied, .restricted:
            MediaLibraryMessageView(
                icon: "lock.fill",
                title: "Photo Access Denied",
                message: "Spatial Stash can't see your photo library. Allow access in Settings to browse and convert your \(kind.noun), or connect a Stash server instead.",
                actionTitle: "Open Settings",
                action: {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            )
        case .limited where !filterActive:
            // No action: the user chose a set, and it contains none of this
            // media kind. That is a valid outcome, so the message says where to
            // widen the selection without framing it as an error.
            MediaLibraryMessageView(
                icon: kind.emptyIcon,
                title: "No \(kind == .photos ? "Photos" : "Videos") to Show",
                message: "Spatial Stash can only see the items you selected, and none of them are \(kind.noun). Choose more in Settings › Privacy & Security › Photos."
            )
        default:
            if filterActive {
                MediaLibraryMessageView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No Matches",
                    message: "No \(kind.noun) in this library match the current filter.",
                    actionTitle: onClearFilters == nil ? nil : "Clear Filters",
                    action: onClearFilters
                )
            } else {
                MediaLibraryMessageView(
                    icon: kind.emptyIcon,
                    title: "No \(kind == .photos ? "Photos" : "Videos") to Show",
                    message: "There are no \(kind.noun) in this library yet."
                )
            }
        }
    }
}
