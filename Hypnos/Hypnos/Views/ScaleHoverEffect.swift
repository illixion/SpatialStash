/*
 Hypnos - Scale Hover Effect

 Custom visionOS 2.0 hover effect that scales thumbnails on focus.

 `CustomHoverEffect` is visionOS-only. On iOS the type exists so call sites
 compile, and `hoverEffect(ScaleHoverEffect())` degrades to the system
 pointer highlight (iPad trackpad / mouse); touch has no hover to react to.
 */

import SwiftUI

#if os(visionOS)

struct ScaleHoverEffect: CustomHoverEffect {
    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, proxy in
            effect.animation(.easeOut(duration: 0.2)) {
                $0.scaleEffect(
                    isActive ? CGSize(width: 1.08, height: 1.08) : CGSize(width: 1, height: 1),
                    anchor: .center
                )
            }
        }
    }
}

#else

struct ScaleHoverEffect {}

extension View {
    func hoverEffect(_ effect: ScaleHoverEffect) -> some View {
        hoverEffect(.highlight)
    }
}

#endif
