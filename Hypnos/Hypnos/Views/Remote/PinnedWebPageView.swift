/*
 Hypnos - Pinned Web Page View

 Thin SwiftUI wrapper around a WKWebView owned by WebPageWindowModel. The model
 owns the instance (not this representable's coordinator) so page state survives
 any view identity churn — that's the whole point of a pinned page.
 */

// tvOS has no WebKit. Stubbed on macOS too, like the other WKWebView views in
// this file's family — see Hypnos/CLAUDE.md "macOS".
#if canImport(WebKit) && !os(macOS)
import SwiftUI
import WebKit

struct PinnedWebPageView: UIViewRepresentable {
    /// Model-owned WebView. Handed in already loaded.
    let model: WebPageWindowModel

    /// Whether the page accepts input. False blocks taps *and* visionOS's
    /// gaze-hover highlights inside the web content, which are distracting on a
    /// page pinned as ambient decoration. Paired with `.allowsHitTesting` on the
    /// SwiftUI side so the blocked taps fall through to the window's
    /// reveal-ornaments gesture.
    let interactionEnabled: Bool

    func makeUIView(context: Context) -> WKWebView {
        let webView = model.webView ?? WKWebView(frame: .zero)
        model.setInteractionEnabled(interactionEnabled)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.setInteractionEnabled(interactionEnabled)
    }
}
#endif
// No macOS stub: nothing on macOS references this type — its sole caller,
// `WebPageWindowView.swift`, is itself excluded from macOS (see that file's
// gate) — unlike the other WebKit views in this app's family, which callers
// outside their own file still construct on every platform.
