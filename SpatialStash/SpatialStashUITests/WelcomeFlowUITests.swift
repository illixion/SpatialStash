/*
 Spatial Stash UI tests - the first-run flow

 This screen is the reason the target exists. It is the one part of the app a
 new user cannot avoid, it is only reachable on a fresh install, and it has
 already shipped two layout regressions that a screenshot would have caught and
 a compile did not: a photo floating 15cm in front of the window, and a spatial
 conversion that zoomed the subject out of frame.

 What is asserted is the flow's contract rather than its pixels — which controls
 exist, what a tap leads to, that a failure lands somewhere usable. Layout
 itself still needs an eye on a screenshot; `xcrun simctl io booted screenshot`
 is the cheap way to get one, and these tests are what get the app to the right
 screen for it.
 */

import RAVEUI
import XCTest

@MainActor
final class WelcomeFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Presentation

    func testWelcomeAppearsOnAFreshInstall() {
        let app = AppLauncher.launch(welcome: .shown)
        app.anyElement(A11y.Welcome.panel).require("The welcome panel")
        // Skippable from the first frame: the flow must never be a gate.
        XCTAssertTrue(app.buttons[A11y.Welcome.skip].waits(), "Skip should be offered immediately")
    }

    func testWelcomeStaysAwayOnceItHasBeenSeen() {
        let app = AppLauncher.launch(welcome: .dismissed)
        // The tab bar is the app proper; if it is up, the panel is not.
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab")
        XCTAssertFalse(
            app.anyElement(A11y.Welcome.panel).exists,
            "The welcome flow should not reappear after being completed"
        )
    }

    func testSkipDismissesTheFlowAndLandsInTheApp() {
        let app = AppLauncher.launch(welcome: .shown)
        let panel = app.anyElement(A11y.Welcome.panel).require("The welcome panel")

        app.buttons[A11y.Welcome.skip].tap()

        panel.requireToVanish("The welcome panel")
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab after skipping")
    }

    // MARK: - Navigation

    func testContinueReachesTheSourcesPageAndBackReturns() {
        let app = AppLauncher.launch(welcome: .shown)
        app.anyElement(A11y.Welcome.panel).require("The welcome panel")

        app.buttons[A11y.Welcome.advance].require("Continue").tap()

        // All three sources are peers — none of them is a prerequisite, which
        // is the whole design of this screen.
        app.anyElement(A11y.Welcome.photosCard).require("The Photos card")
        XCTAssertTrue(app.anyElement(A11y.Welcome.serverCard).waits(), "The media-server card")
        XCTAssertTrue(app.anyElement(A11y.Welcome.backupCard).waits(), "The restore-a-backup card")

        app.buttons[A11y.Welcome.back].require("Back").tap()

        app.buttons[A11y.Welcome.advance].require("Continue, after going back")
    }

    func testTheFlowCanBeCompletedWithoutConfiguringAnything() {
        let app = AppLauncher.launch(welcome: .shown)
        let panel = app.anyElement(A11y.Welcome.panel).require("The welcome panel")

        app.buttons[A11y.Welcome.advance].require("Continue").tap()
        app.buttons[A11y.Welcome.finish].require("The dismiss button").tap()

        panel.requireToVanish("The welcome panel")
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab")
    }

    func testExpandingTheServerFormOffersItsFields() {
        let app = AppLauncher.launch(welcome: .shown)
        app.buttons[A11y.Welcome.advance].require("Continue").tap()
        app.anyElement(A11y.Welcome.serverCard).require("The media-server card")

        // Collapsed by default — a server is one of three options, not the
        // headline — so the form has to be asked for.
        app.buttons["Set Up a Server"].require("The server disclosure button").tap()

        app.textFields[A11y.Welcome.serverURLField].require("The server URL field")
        XCTAssertTrue(app.secureTextFields[A11y.Welcome.serverKeyField].waits(), "The API key field")
        // Nothing to connect to yet, so Connect must not be tappable: it
        // commits the server as the library source, and doing that on an empty
        // URL is how you get an app pointed at nothing.
        XCTAssertFalse(
            app.buttons[A11y.Welcome.serverConnect].isEnabled,
            "Connect should stay disabled until a URL is entered"
        )
    }

    // MARK: - The sample conversion

    /// The one test whose outcome legitimately differs by destination.
    ///
    /// `ImagePresentationComponent`'s depth generation is device-only — in the
    /// simulator it fails with `Spatial3DImageError error 9` — and the designed
    /// response is to drop back to the flat photograph and offer the conversion
    /// again. So both endings are correct, and what is actually being tested is
    /// that neither one strands the screen: a spinner that never resolves, or a
    /// panel with no photo in it, fails here on both.
    func testConvertingTheSampleEitherSucceedsOrFallsBackToFlat() {
        let app = AppLauncher.launch(welcome: .shown)
        app.anyElement(A11y.Welcome.panel).require("The welcome panel")

        let convert = app.buttons[A11y.Welcome.sampleConvert]
        guard convert.waits(timeout: 15) else {
            // No bundled sample resolves to a file URL in this build. That is a
            // legitimate state (`MissingSampleCard` covers it) but not one the
            // shipped app should be in, so say so rather than passing quietly.
            XCTFail("The sample photo never loaded, so Convert to 3D was never offered")
            return
        }
        convert.tap()

        let modePicker = app.anyElement(A11y.Welcome.sampleModePicker)
        let generationSucceeded = modePicker.waits(timeout: 60)

        if generationSucceeded {
            // Flat and Spatial 3D are both reachable, and the switch starts on 3D.
            XCTAssertTrue(app.buttons["Flat"].exists, "A Flat option")
            XCTAssertTrue(app.buttons["Spatial 3D"].exists, "A Spatial 3D option")
        } else {
            XCTAssertTrue(
                convert.waits(timeout: 15),
                "Generation did not finish and Convert to 3D never came back — the screen is stuck"
            )
        }

        // Either way the flow still works.
        app.buttons[A11y.Welcome.advance].require("Continue").tap()
        app.anyElement(A11y.Welcome.photosCard).require("The Photos card")
    }
}
