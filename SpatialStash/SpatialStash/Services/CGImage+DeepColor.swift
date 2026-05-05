/*
 Spatial Stash - Deep Color CGImage Utilities

 Helpers for redrawing/resizing CGImages while preserving source bit depth.
 Used to avoid the implicit 8-bit flattening that UIGraphicsImageRenderer
 (and a default 8-bit CGContext) would impose on deep-color sources such
 as 16-bit JXL upscaler output.

 The deep path uses a 16bpc unsigned RGBA premultiplied buffer in the
 source's color space (or extendedLinearDisplayP3 if absent). 8-bit sources
 keep the standard 8bpc premultipliedLast / sRGB layout.
 */

import CoreGraphics
import os

enum CGImageDeepColor {
    /// Re-render `image` into a fresh standalone CGImage at the given pixel
    /// dimensions, preserving the source's bit depth. Pass `nil` for size to
    /// keep the original dimensions (rebake with no resize). Returns nil if
    /// no compatible context can be allocated.
    static func redraw(_ image: CGImage, size: (width: Int, height: Int)? = nil) -> CGImage? {
        let width = size?.width ?? image.width
        let height = size?.height ?? image.height
        guard width > 0, height > 0 else { return nil }

        let isDeep = image.bitsPerComponent > 8

        if isDeep, let deep = drawIntoContext(image, width: width, height: height, deep: true) {
            return deep
        }
        return drawIntoContext(image, width: width, height: height, deep: false)
    }

    private static func drawIntoContext(_ image: CGImage, width: Int, height: Int, deep: Bool) -> CGImage? {
        let colorSpace: CGColorSpace
        if let cs = image.colorSpace {
            colorSpace = cs
        } else if deep, let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            colorSpace = cs
        } else if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
            colorSpace = cs
        } else {
            return nil
        }

        let bitsPerComponent = deep ? 16 : 8
        let bitmapInfo: UInt32 = deep
            ? (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            : CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
