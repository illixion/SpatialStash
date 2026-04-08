/*
 Spatial Stash - Sobel Focus Analyzer

 Finds the visual focus point of an image using Sobel edge detection.
 Used for Ken Burns zoom animation to target interesting regions.
 */

import CoreGraphics
import CoreImage

enum SobelFocusAnalyzer {
    /// Analyze an image and return the normalized focus point (0-1, 0-1)
    /// where edges are most concentrated, suitable for Ken Burns animation origin.
    static func focusPoint(from cgImage: CGImage, gridSize: Int = 3) -> CGPoint {
        let analysisSize = 256
        let ciImage = CIImage(cgImage: cgImage)

        // Downsample for performance
        let scaleX = Double(analysisSize) / Double(cgImage.width)
        let scaleY = Double(analysisSize) / Double(cgImage.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context = CIContext(options: [.useSoftwareRenderer: true])
        let extent = scaled.extent

        guard let pixelBuffer = context.createCGImage(scaled, from: extent) else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        // Get grayscale pixel data
        let width = pixelBuffer.width
        let height = pixelBuffer.height
        guard let dataProvider = pixelBuffer.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let bytesPerPixel = pixelBuffer.bitsPerPixel / 8
        let bytesPerRow = pixelBuffer.bytesPerRow

        // Convert to grayscale
        var gray = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Float(bytes[offset]) / 255.0
                let g = Float(bytes[offset + 1]) / 255.0
                let b = Float(bytes[offset + 2]) / 255.0
                gray[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Apply Sobel operator
        var edgeMagnitude = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let tl = gray[(y - 1) * width + (x - 1)]
                let tc = gray[(y - 1) * width + x]
                let tr = gray[(y - 1) * width + (x + 1)]
                let ml = gray[y * width + (x - 1)]
                let mr = gray[y * width + (x + 1)]
                let bl = gray[(y + 1) * width + (x - 1)]
                let bc = gray[(y + 1) * width + x]
                let br = gray[(y + 1) * width + (x + 1)]

                let gx = -tl + tr - 2 * ml + 2 * mr - bl + br
                let gy = -tl - 2 * tc - tr + bl + 2 * bc + br

                edgeMagnitude[y * width + x] = sqrt(gx * gx + gy * gy)
            }
        }

        // Find grid cell with highest edge density
        let cellW = width / gridSize
        let cellH = height / gridSize
        var maxEnergy: Float = 0
        var bestCell = (row: 0, col: 0)

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                var energy: Float = 0
                let startY = row * cellH
                let startX = col * cellW
                for y in startY..<min(startY + cellH, height) {
                    for x in startX..<min(startX + cellW, width) {
                        energy += edgeMagnitude[y * width + x]
                    }
                }
                if energy > maxEnergy {
                    maxEnergy = energy
                    bestCell = (row, col)
                }
            }
        }

        // Return center of best cell as normalized coordinates
        let focusX = (Double(bestCell.col) + 0.5) / Double(gridSize)
        let focusY = (Double(bestCell.row) + 0.5) / Double(gridSize)
        return CGPoint(x: focusX, y: focusY)
    }

    /// Compute average luminance of an image (0-1). Used for dynamic brightness.
    static func averageLuminance(from cgImage: CGImage) -> Float {
        let size = 64
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return 0.5 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        var totalLuminance: Float = 0
        let pixelCount = size * size
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(bytes[offset]) / 255.0
            let g = Float(bytes[offset + 1]) / 255.0
            let b = Float(bytes[offset + 2]) / 255.0
            totalLuminance += 0.299 * r + 0.587 * g + 0.114 * b
        }

        return totalLuminance / Float(pixelCount)
    }
}
