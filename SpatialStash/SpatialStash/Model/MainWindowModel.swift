/*
 Spatial Stash - Main Window Model

 Per-window navigation state for the main app window. Each instance of the
 main WindowGroup gets its own model so that tab selection does not clone
 across multiple open main windows.
 */

import SwiftUI

@MainActor
@Observable
class MainWindowModel {
    var selectedTab: Tab = .pictures

    /// Tracks the last content tab (pictures or videos) for filter context
    var lastContentTab: Tab = .pictures

    /// Incremented when Local tab is tapped while already on Local tab
    var localTabReselected: Int = 0
}
