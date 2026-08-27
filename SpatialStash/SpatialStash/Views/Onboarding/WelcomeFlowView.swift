/*
 Spatial Stash - Welcome Flow

 First run, in two screens: what the app does, then where to point it.

 It is an overlay over the main window rather than a sheet, because a sheet on
 visionOS is a small panel floating in front of the window and the first screen
 is a photo the user is meant to lean into. Taking the whole window also means
 the tab ornament can be hidden for the duration — there is nothing useful in
 those tabs until a library is chosen, and a tab bar visible under a welcome
 screen invites people to escape into an empty gallery and conclude the app is
 broken.

 The flow is skippable from the first frame and never blocks. Someone who
 dismisses it lands on the Pictures tab, which already explains the permission
 state it is in — the welcome flow is the pleasant path to a configured app, not
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

    var isLastPage: Bool { page == .sources }

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
    /// Whether any source has been set up, which changes the last button from
    /// "skip this" to "go and look".
    @State private var didConfigureSource = false

    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch flow.page {
                case .intro:
                    introPage
                case .sources:
                    WelcomeSourcesPage(onSourceConfigured: { didConfigureSource = true })
                }
            }
            .id(flow.page)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .animation(.smooth(duration: 0.3), value: flow.page)
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .background(.regularMaterial)
    }

    // MARK: - Intro

    private var introPage: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text("Photos, with depth")
                    .font(.system(size: 44, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Spatial Stash converts flat photos and videos into spatial 3D, right here on the device. Nothing is uploaded.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }

            WelcomeSampleStage()
                .frame(maxHeight: .infinity)
        }
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
        .padding(.top, 24)
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
