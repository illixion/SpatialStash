/*
 Spatial Stash - Diorama Reveal Hover Effect

 visionOS 2 custom hover effect that fades a view from invisible to
 fully visible while gaze is on it. Used to overlay the diorama
 backdrop+foreground pair on top of a flat thumbnail so the parallax
 only materializes when the user is actually looking at the cell —
 since visionOS doesn't expose gaze callbacks to Swift code, the
 hover-effect closure is the only sandboxed signal we can drive
 visuals from.
 */

import SwiftUI

struct DioramaRevealHoverEffect: CustomHoverEffect {
    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, _ in
            effect.animation(.easeInOut(duration: 0.3)) {
                $0.opacity(isActive ? 1 : 0)
            }
        }
    }
}
