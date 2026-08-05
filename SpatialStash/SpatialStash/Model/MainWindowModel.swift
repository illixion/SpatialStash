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

    /// Folder the Local tab is currently showing, as path components under
    /// Documents (`["Photos", "Wallpapers"]`). Empty means the root folder
    /// picker.
    ///
    /// Lives here rather than in `LocalTabView`'s own state because the tab bar
    /// ornament's slideshow button has to know what's on screen to start a
    /// slideshow of it — and because ContentView keys the tab content on
    /// `selectedTab`, so view-local state wouldn't survive a trip to another
    /// tab and back.
    var localFolderPath: [String] = []
}
