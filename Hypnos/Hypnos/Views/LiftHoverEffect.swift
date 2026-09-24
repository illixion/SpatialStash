/*
 Hypnos - Lift Hover Effect

 Custom visionOS 2.0 hover effect that lifts thumbnails on focus
 by adding depth offset and a subtle scale.

 `CustomHoverEffect` is visionOS-only. On iOS the type exists so call sites
 compile, and `hoverEffect(LiftHoverEffect())` degrades to the system
 pointer highlight (iPad trackpad / mouse); touch has no hover to react to.
 */

import SwiftUI

#if os(visionOS)

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

#elseif os(macOS)

// `.hoverEffect` doesn't exist on macOS at all — a real mouse cursor already
// shows hover with no help needed, unlike iPad's trackpad pointer (which
// `.hoverEffect(.lift)` is built for). No-op.
struct LiftHoverEffect {}

extension View {
    func hoverEffect(_ effect: LiftHoverEffect) -> some View {
        self
    }
}

#else

struct LiftHoverEffect {}

extension View {
    func hoverEffect(_ effect: LiftHoverEffect) -> some View {
        hoverEffect(.lift)
    }
}

#endif
