/*
 Spatial Stash - Animated GIF Detail View

 Full-screen view for displaying animated GIFs without RealityKit.
 GIFs cannot be converted to spatial 3D, so they display as 2D animations.
 */

import SwiftUI

struct AnimatedGIFDetailView: View {
    let imageData: Data
    let aspectRatio: CGFloat

    var body: some View {
        GeometryReader { geometry in
            AnimatedImageView(data: imageData, contentMode: .scaleAspectFit)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .background(Color.black)
    }
}
