/*
 Spatial Stash UI tests - the Local library

 Local needs no permission and no setup — unlike Photos (a system prompt) or
 Stash (a server to configure) — so it carries no enable toggle and is simply
 always one of the offered sources. Local has no seeded content in this
 harness (that needs `simctl addmedia` run from outside the test process —
 see `SharedTabBarUITests`), so every test here runs against an empty
 Documents/Photos, which is itself worth covering: an empty Local still has
 to be offered and still has to render a (empty, but present and
 refreshable) folder browser, never disappear for having nothing in it.
 Actually navigating a folder is out of reach until seeding exists.
 */

import RAVEUI
import XCTest

@MainActor
final class LocalLibraryUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Photos and Local are both always available — no server, no toggle,
    /// nothing to set up — so even a completely fresh install has two
    /// sources to switch between.
    func testLibrarySwitchIsOfferedOnAFreshInstallWithNoServer() {
        let app = AppLauncher.launch(welcome: .dismissed)
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab").tap()

        app.buttons[A11y.librarySwitch].require("The library-switch dropdown, with Photos and Local")
    }

    /// Once Local is the library in force, Albums has to show its folder
    /// browser rather than the Photos/Stash container grid, and Filters has
    /// nothing to offer (no tags, albums or galleries for a flat file tree).
    /// Documents/Photos is empty in this harness — which is the point: an
    /// empty Local still has to be selectable and still has to render a
    /// (empty, but present and refreshable) folder browser, not disappear.
    func testSwitchingToLocalShowsItsFolderBrowserAndHidesFilters() {
        let app = AppLauncher.launch(welcome: .dismissed)
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
