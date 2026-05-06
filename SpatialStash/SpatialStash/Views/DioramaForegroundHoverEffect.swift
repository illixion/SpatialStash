/*
 Spatial Stash - Diorama Foreground Hover Effect

 Applied to the masked foreground layer of a thumbnail diorama. Grows
 the foreground beyond the container's hover scale and adds a subtle
 3D tilt so the subject reads as popping forward on gaze, without
 needing dynamic z-offset (which the hover-effect transform vocabulary
 doesn't support).
 */

import SwiftUI

struct DioramaForegroundHoverEffect: CustomHoverEffect {
    var scale: CGFloat = 1.10

    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, _ in
            effect.animation(.easeOut(duration: 0.25)) {
                $0.scaleEffect(isActive ? scale : 1, anchor: .center)
            }
        }
    }
}
