/*
 Spatial Stash - Welcome Flow

 First run, in two screens: what the app does, then where to point it.

 Presented as a **modal panel** over the main window — a dimmed backdrop and a
 glass card, laid out like a sheet. Not an actual `.sheet`, for one reason: the
 intro screen mounts a `RealityView` to show the photo in spatial 3D, and a
 sheet's presentation clips depth, which would flatten the one thing the screen
 exists to demonstrate. Everything else about it is sheet-shaped, including
 dimming what is behind so the tab underneath stops competing for attention —
 the first version drew straight over the window and Settings showed through.

 The intro's layout is a spread: the photograph fills the left edge of the panel
 top to bottom, the words and the switch sit on the right. That keeps the
 picture the largest thing on screen without the copy having to float on top of
 it.

 The flow is skippable from the first frame and never blocks. Someone who
 dismisses it lands on the Pictures tab, which already explains whatever
 permission state it is in — this is the pleasant path to a configured app, not
 a gate in front of one.
 */

import SwiftUI

@MainActor
@Observable
final class WelcomeFlowModel {

    enum Page: Int, CaseIterable {
        case intro
        case sources
    }

    var page: Page = .intro

    func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else { return }
        page = next
    }

    func retreat() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        page = previous
    }
}

struct WelcomeFlowView: View {
    @Environment(AppModel.self) private var appModel
    @State private var flow = WelcomeFlowModel()
    @State private var sample = WelcomeSampleModel()
    /// Whether any source has been set up, which changes the last button from
    /// "skip this" to "go and look".
    @State private var didConfigureSource = false

    let onFinish: () -> Void

    private let cornerRadius: CGFloat = 34

    var body: some View {
        ZStack {
            // Modality, and cover for the tab behind.
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            panel
                .frame(maxWidth: 1120, maxHeight: 660)
                .padding(24)
        }
    }

    private var panel: some View {
        Group {
            switch flow.page {
            case .intro:
                introSpread
            case .sources:
                sourcesPage
            }
        }
        .animation(.smooth(duration: 0.3), value: flow.page)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        .glassBackgroundEffect(in: shape)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    // MARK: - Intro

    private var introSpread: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                WelcomeSampleImage(model: sample)
                    // Width derived from the photo's own aspect, so a fitted
                    // image exactly fills its column: no mat down the sides,
                    // and — the reason it matters — no jump in framing when
                    // spatial 3D takes over, since that fits into the same box.
                    // Capped so a landscape sample still leaves the copy a
                    // readable column.
                    .frame(width: min(geometry.size.height * sample.aspectRatio,
                                      geometry.size.width * 0.55))
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Photos, with depth")
                            .font(.system(size: 40, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Spatial Stash turns flat photos and videos into spatial 3D, right here on the device. Nothing is uploaded.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Try it on the photo beside this text.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }

                    WelcomeSampleControls(model: sample)
                        .padding(.top, 32)

                    Spacer(minLength: 24)

                    footer
                }
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Sources

    private var sourcesPage: some View {
        VStack(spacing: 0) {
            WelcomeSourcesPage(onSourceConfigured: { didConfigureSource = true })
                .frame(maxHeight: .infinity)
            footer
        }
        .padding(36)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            leadingButton
            Spacer()
            pageDots
            Spacer()
            trailingButton
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch flow.page {
        case .intro:
            Button("Skip") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        case .sources:
            Button {
                flow.retreat()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(WelcomeFlowModel.Page.allCases, id: \.rawValue) { page in
                Circle()
                    .fill(page == flow.page ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch flow.page {
        case .intro:
            Button {
                flow.advance()
            } label: {
                Text("Continue")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
        case .sources:
            // Two button styles rather than a conditional style: `.bordered`
            // and `.borderedProminent` are different types and cannot share a
            // ternary.
            if didConfigureSource {
                Button { finish() } label: {
                    Text("Start Browsing").padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { finish() } label: {
                    Text("Not Now").padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func finish() {
        appModel.hasCompletedWelcome = true
        onFinish()
    }
}
