/*
 Spatial Stash UI tests - the Local library

 Local has no seeded content in this harness (that needs `simctl addmedia` run
 from outside the test process — see `SharedTabBarUITests`), so these tests
 cover what is reachable without it: turning the source on, it joining the
 library switch, and Albums rendering its folder browser instead of the
 Photos/Stash container grid once it's the one in force. Actually navigating a
 folder is out of reach until seeding exists.
 */

import RAVEUI
import XCTest

@MainActor
final class LocalLibraryUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// With no server configured and Local off, there is only one source —
    /// nothing to switch between — so the button should be absent. Turning
    /// the Settings toggle on is what should make it appear.
    func testEnablingLocalFilesFromSettingsAddsTheLibrarySwitch() {
        let app = AppLauncher.launch(welcome: .dismissed)
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab").tap()

        XCTAssertFalse(
            app.buttons[A11y.librarySwitch].exists,
            "With only Photos available, there is nothing to switch to"
        )

        app.buttons[RAVEA11y.tab("settings")].require("The Settings tab").tap()
        // "Local Files" sits well down the list, behind Display and Slideshow
        // Defaults — a SwiftUI List only materializes cells near the visible
        // area, so the toggle isn't in the accessibility tree until scrolled
        // into view.
        let toggle = app.anyElement(A11y.Settings.enableLocalLibrary)
        let window = app.windows.firstMatch
        for _ in 0..<6 where !toggle.exists {
            window.swipeUp()
        }
        toggle.require("The Enable Local Files toggle").tap()

        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab").tap()
        app.buttons[A11y.librarySwitch].require("The library-switch button, with Local enabled")
    }

    /// Once Local is the library in force, Albums has to show its folder
    /// browser rather than the Photos/Stash container grid, and Filters has
    /// nothing to offer (no tags, albums or galleries for a flat file tree).
    func testSwitchingToLocalShowsItsFolderBrowserAndHidesFilters() {
        let app = AppLauncher.launch(welcome: .dismissed, defaults: ["enableLocalLibrary": "1"])
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab").tap()

        // Only Photos and Local are available (no server configured), so one
        // tap of the two-way switch reaches Local.
        app.buttons[A11y.librarySwitch].require("The library-switch button").tap()

        app.buttons[RAVEA11y.tab("albums")].require("The Albums tab").tap()
        app.anyElement(A11y.Albums.localBrowser).require("The Local folder browser, with Local active")

        XCTAssertFalse(
            app.buttons[RAVEA11y.tab("filters")].exists,
            "Filters has nothing to filter by while browsing Local"
        )
    }
}
