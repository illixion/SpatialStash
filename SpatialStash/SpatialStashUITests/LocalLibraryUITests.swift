/*
 Spatial Stash UI tests - the Local library

 Local has no seeded content in this harness (that needs `simctl addmedia` run
 from outside the test process — see `SharedTabBarUITests`), so every test here
 runs against an empty Documents/Photos — which is itself the thing worth
 covering: what's offered has to depend only on the Settings toggle, never on
 whether Local currently has anything in it, or a folder that starts out empty
 (then gets files dropped into it from outside the app) would vanish from the
 switch instead of staying reachable to pull-to-refresh. Actually navigating a
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
        // The tap's effect (an @Observable property flip driving a computed
        // tab-bar condition) has shown up a beat slower than `waitForExistence`
        // covers when this runs back-to-back with the next test rather than
        // standalone — wait for the switch to actually report on before
        // trusting it and moving on.
        _ = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)],
            timeout: 3
        )

        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab").tap()
        app.buttons[A11y.librarySwitch].require("The library-switch button, with Local enabled")
    }

    /// Once Local is the library in force, Albums has to show its folder
    /// browser rather than the Photos/Stash container grid, and Filters has
    /// nothing to offer (no tags, albums or galleries for a flat file tree).
    /// Documents/Photos is empty in this harness — which is the point: an
    /// empty Local still has to be selectable and still has to render a
    /// (empty, but present and refreshable) folder browser, not disappear.
    func testSwitchingToLocalShowsItsFolderBrowserAndHidesFilters() {
        let app = AppLauncher.launch(welcome: .dismissed, defaults: ["enableLocalLibrary": "1"])
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab").tap()

        app.buttons[A11y.librarySwitch].require("The library-switch dropdown").tap()
        app.buttons[A11y.librarySwitchOption("local")].require("The Local Files option").tap()

        app.buttons[RAVEA11y.tab("albums")].require("The Albums tab").tap()
        app.anyElement(A11y.Albums.localBrowser).require("The Local folder browser, with Local active")
        app.staticTexts["No files or folders found"].require(
            "The empty state — present rather than the browser disappearing"
        )

        XCTAssertFalse(
            app.buttons[RAVEA11y.tab("filters")].exists,
            "Filters has nothing to filter by while browsing Local"
        )
    }
}
