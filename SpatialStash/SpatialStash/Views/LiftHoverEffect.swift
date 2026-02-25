/*
 Spatial Stash - Lift Hover Effect

 Custom visionOS 2.0 hover effect that lifts thumbnails on focus
 by adding depth offset and a subtle scale.
 */

import SwiftUI

struct LiftHoverEffect: CustomHoverEffect {
    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, _ in
            effect.animation(.easeOut(duration: 0.2)) {
                $0.scaleEffect(
                    isActive ? CGSize(width: 1.05, height: 1.05) : CGSize(width: 1, height: 1),
                    anchor: .center
                )
                .offset(y: isActive ? -4 : 0)
            }
        }
    }
}
