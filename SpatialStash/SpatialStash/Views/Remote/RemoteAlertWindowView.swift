/*
 Spatial Stash - Remote Alert Window View

 Displays text alerts triggered by WebSocket showText commands.
 Appears as a standalone window in front of the user.
 */

import SwiftUI

struct RemoteAlertWindowView: View {
    let windowValue: RemoteAlertWindowValue

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 24) {
                if let imageUrl = windowValue.imageUrl, let url = URL(string: imageUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 300)
                    } placeholder: {
                        ProgressView()
                    }
                }

                Text(windowValue.text)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private var backgroundColor: Color {
        Color(hex: windowValue.bgColorHex) ?? .black
    }
}

private extension Color {
    init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }

        guard hexString.count == 6,
              let value = UInt64(hexString, radix: 16) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
