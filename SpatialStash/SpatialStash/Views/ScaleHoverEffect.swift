/*
 Spatial Stash - Scale Hover Effect

 Custom visionOS 2.0 hover effect that scales thumbnails on focus.
 */

import SwiftUI

struct ScaleHoverEffect: CustomHoverEffect {
    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, proxy in
            effect.animation(.easeOut(duration: 0.2)) {
                $0.scaleEffect(
                    isActive ? CGSize(width: 1.15, height: 1.15) : CGSize(width: 1, height: 1),
                    anchor: .center
                )
            }
        }
    }
}
