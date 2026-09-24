/*
 Hypnos - Platform Image

 The single seam that lets ~30 files' worth of `UIImage` code (226 call
 sites — decode, thumbnail, cache, background removal, auto-enhance) keep
 compiling on macOS unchanged, instead of renaming every one of them to a new
 `PlatformImage` type.

 `PlatformImage` is the name new macOS-aware code should use. But `UIImage`
 itself is also aliased to `NSImage` on macOS, because the alternative —
 teaching 33 files' worth of shared image-processing code to say
 `PlatformImage` instead — is exactly the "scattered edits" the platform
 seams in this app are supposed to avoid (see `Hypnos/CLAUDE.md` "macOS").
 `NSImage` lacks the handful of UIKit-ism this codebase actually calls on a
 `UIImage` — `.cgImage`, `.scale`, `.imageOrientation`, `pngData()`,
 `jpegData(compressionQuality:)`, and the `init(cgImage:)` family — so this
 file adds them as an extension. `.scale` and `.imageOrientation` are stored
 via associated objects since `NSImage` has no such concept: macOS image
 orientation/scale metadata is normally baked into the pixel data by the
 point any of this code runs, so this is bookkeeping for round-tripping a
 value the caller already computed, not a source of truth macOS derives
 itself.

 Known gap: `NSImage`'s coordinate system is bottom-left-origin and
 resolution-independent in ways `UIImage` isn't, so pixel-exact parity with
 iOS/visionOS (especially anything orientation-sensitive) is unverified on
 macOS — this seam buys compilation and the common decode/encode paths, not
 a guarantee that every image transform produces identical output.
 */

import SwiftUI

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
import ImageIO
import ObjectiveC

public typealias PlatformImage = NSImage

/// Compatibility alias so every existing `UIImage` call site in the shared
/// module keeps compiling on macOS — see the file comment above.
public typealias UIImage = NSImage

extension NSImage {
    /// Mirrors `UIImage.Orientation`'s cases and raw values exactly, so the
    /// `switch orientation { case .up: ... }` mapping code written against
    /// `UIImage.Orientation` (e.g. `BackgroundRemovalCache`'s
    /// `cgImagePropertyOrientation(for:)`) compiles unchanged.
    public enum Orientation: Int, Sendable {
        case up = 0, down, left, right, upMirrored, downMirrored, leftMirrored, rightMirrored
    }

    // `nonisolated(unsafe)`: these are never mutated after being read as
    // pointers — `objc_getAssociatedObject`/`objc_setAssociatedObject` use
    // the address as an opaque key, not the stored `0` value — so treating
    // them as shared mutable state is a false positive, the same shape as
    // any other Objective-C associated-object key.
    private nonisolated(unsafe) static var scaleKey: UInt8 = 0
    private nonisolated(unsafe) static var orientationKey: UInt8 = 0

    /// Always 1.0 unless a caller set it explicitly via
    /// `init(cgImage:scale:orientation:)` — `NSImage` has no backing-scale
    /// concept of its own (it is resolution-independent).
    public var scale: CGFloat {
        get { (objc_getAssociatedObject(self, &Self.scaleKey) as? CGFloat) ?? 1.0 }
        set { objc_setAssociatedObject(self, &Self.scaleKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Always `.up` unless a caller set it explicitly. Bookkeeping only —
    /// see the file comment.
    public var imageOrientation: Orientation {
        get { (objc_getAssociatedObject(self, &Self.orientationKey) as? Orientation) ?? .up }
        set { objc_setAssociatedObject(self, &Self.orientationKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Matches `UIImage(cgImage:scale:orientation:)`. Not pixel-rotated for a
    /// non-`.up` orientation (macOS has no equivalent lazy-orientation
    /// image representation) — `orientation` is stored for callers that read
    /// it back, not applied to the pixels.
    public convenience init(cgImage: CGImage, scale: CGFloat, orientation: Orientation) {
        self.init(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        self.scale = scale
        self.imageOrientation = orientation
    }

    /// Matches `UIImage(cgImage:)`, which `NSImage` has no equivalent for
    /// (its own `init(cgImage:size:)` always requires an explicit size).
    public convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Matches `UIImage.cgImage`. `NSImage` has no stored `CGImage` — this
    /// asks the best representation to rasterize one at its own pixel size.
    public var cgImage: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Matches `UIImage.pngData()`.
    public func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Matches `UIImage.jpegData(compressionQuality:)`.
    public func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    /// Matches `UIImage.byPreparingForDisplay()` — a Core Animation
    /// pre-decode hint with no `NSImage` equivalent (AppKit's own image
    /// drawing doesn't have the same first-composite decode cost UIKit's
    /// does). A no-op returning `self` — the caller's fallback
    /// (`byPreparingForDisplay() ?? image`) already handles that.
    public func byPreparingForDisplay() async -> NSImage? {
        self
    }
}
#endif

// MARK: - SwiftUI `Image` bridge

extension Image {
    /// SwiftUI's `Image(uiImage:)` and `Image(nsImage:)` are two different
    /// initializers with two different argument labels, even though
    /// `UIImage`/`NSImage` are the same type via the alias above — so the
    /// ~15 call sites in this app that build an `Image` from a loaded
    /// `PlatformImage` go through this one spelling instead of branching at
    /// each site.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}
