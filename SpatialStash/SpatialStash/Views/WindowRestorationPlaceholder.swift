import SwiftUI

/// Basic SwiftUI-only content shown until a restored window presents real
/// media. If this is also invisible, the failure is above the media renderer
/// (scene/window compositor or restoration), not an image decode or Metal draw.
struct WindowRestorationPlaceholder: View {
    let title: String
    let windowID: UUID
    let status: String

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.12)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text(title)
                    .font(.title2.weight(.semibold))

                Text(status)
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text("Window \(windowID.uuidString.prefix(8))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)

                Text("If this placeholder is invisible, the restored SwiftUI scene itself is not compositing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(32)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
