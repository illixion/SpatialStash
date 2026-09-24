/*
 Hypnos - hosts a FilmVideoPlayer's display layer in SwiftUI.

 macOS makes the layer the view's backing layer, so AppKit sizes it. UIKit
 has no per-instance backing layer, so there it is a sublayer kept at the
 view's bounds.
 */

import AVFoundation
import SwiftUI
#if os(tvOS) || os(visionOS)
import AVKit
#endif

#if os(macOS)
public struct FilmVideoView: NSViewRepresentable {
    let player: FilmVideoPlayer

    public init(player: FilmVideoPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: player.displayLayer)
    }

    public func updateNSView(_ view: LayerHostView, context: Context) {}

    public final class LayerHostView: NSView {
        private let videoLayer: AVSampleBufferDisplayLayer

        init(videoLayer: AVSampleBufferDisplayLayer) {
            self.videoLayer = videoLayer
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override public func makeBackingLayer() -> CALayer {
            videoLayer.backgroundColor = NSColor.black.cgColor
            return videoLayer
        }
    }
}
#else
public struct FilmVideoView: UIViewRepresentable {
    let player: FilmVideoPlayer

    public init(player: FilmVideoPlayer) {
        self.player = player
    }

    public func makeUIView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: player.displayLayer)
    }

    public func updateUIView(_ view: LayerHostView, context: Context) {
        #if os(tvOS) || os(visionOS)
        view.displayCriteria = player.displayCriteria
        #endif
    }

    public final class LayerHostView: UIView {
        private let videoLayer: AVSampleBufferDisplayLayer
        #if os(tvOS) || os(visionOS)
        /// Stated to the window's display manager while the view is in it.
        var displayCriteria: AVDisplayCriteria? {
            didSet { applyDisplayCriteria() }
        }
        private weak var criteriaWindow: UIWindow?

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            applyDisplayCriteria()
        }

        private func applyDisplayCriteria() {
            if let criteriaWindow, criteriaWindow !== window {
                criteriaWindow.avDisplayManager.preferredDisplayCriteria = nil
            }
            criteriaWindow = window
            guard let window else { return }
            window.avDisplayManager.preferredDisplayCriteria = displayCriteria
            print("FilmVideoView: display criteria \(displayCriteria == nil ? "cleared" : "set"), "
                + "matching enabled=\(window.avDisplayManager.isDisplayCriteriaMatchingEnabled)")
        }
        #endif

        init(videoLayer: AVSampleBufferDisplayLayer) {
            self.videoLayer = videoLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(videoLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override public func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
