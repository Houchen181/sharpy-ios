import XCTest

/// Scripted walkthrough that CI records for the intro video. Each step prints
/// "TOURMARK <name> <unix time>" so the editor (tools/make_intro.py) can line
/// captions up with the footage. Pauses are long enough to read the screen.
/// Steps are forgiving: a missing element skips that step instead of ending the tour.
final class TourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-demo", "-ui-tour", "-ui-tab", "onboarding"]
        app.launch()
        _ = app.buttons["Get started"].waitForExistence(timeout: 20)
        pause(1.0)

        // Onboarding
        mark("welcome")
        pause(4.0)
        tap(app.buttons["Get started"])
        pause(1.2)

        mark("topics")
        tap(button(app, containing: "Immunology"))
        pause(0.9)
        tap(button(app, containing: "Quantum computing"))
        pause(0.9)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            pause(0.6)
            field.typeText("Macroeconomics")
            pause(0.8)
            tap(app.buttons["Add"])
        }
        pause(2.0)
        tap(app.buttons["Continue"])
        pause(1.2)

        mark("level")
        tap(button(app, containing: "Professional"))
        pause(1.6)
        tap(app.buttons["Continue"])
        pause(1.2)

        mark("goal")
        tap(button(app, containing: "Regular"))
        pause(1.6)
        tap(app.buttons["Continue"])
        pause(1.2)

        mark("reminder")
        pause(2.2)
        tap(app.buttons["Turn on reminders"])
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) {
            pause(1.4)
            allow.tap()
        }

        // Home
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 10)
        pause(0.8)
        mark("home")
        pause(4.0)

        // Session: the demo server "researches" for a few seconds first.
        mark("start")
        tap(button(app, containing: "Keep going"))
        _ = button(app, containing: "False").waitForExistence(timeout: 15)
        pause(0.4)

        mark("q_true_false")
        pause(3.5)
        tap(button(app, containing: "False"))
        pause(6.5)
        tap(app.buttons["Continue"])
        pause(0.8)

        mark("q_single")
        pause(3.0)
        tap(button(app, containing: "Helper T cells"))
        pause(6.5)
        tap(app.buttons["Continue"])
        pause(0.8)

        mark("q_select_all")
        pause(3.5)
        for choice in ["Maximizing employment", "Stabilizing prices", "Moderating long-term"] {
            tap(button(app, containing: choice))
            pause(0.8)
        }
        pause(0.6)
        tap(app.buttons["Check"])
        pause(6.0)
        tap(app.buttons["Continue"])
        pause(0.8)

        mark("q_spot")
        pause(4.5)
        tap(button(app, containing: "1930s"))
        pause(5.5)
        tap(app.buttons["Continue"])
        pause(0.8)

        mark("q_last")
        pause(3.0)
        tap(button(app, containing: "True"))
        pause(4.0)
        tap(app.buttons["Finish"])
        pause(0.8)

        mark("summary")
        pause(5.0)
        tap(app.buttons["Done"])
        pause(1.0)
        mark("home_done")
        pause(3.0)

        // Discover
        mark("discover")
        tapTab(app, "Discover")
        pause(4.5)
        let window = app.windows.firstMatch
        window.swipeUp(velocity: .slow)
        pause(1.5)
        mark("discover_check")
        let pragmatics = app.buttons["Pragmatics"]
        if pragmatics.waitForExistence(timeout: 3) {
            if !pragmatics.isHittable { window.swipeUp(velocity: .slow) }
            tap(pragmatics)
        }
        pause(3.5)
        window.swipeUp(velocity: .slow)
        pause(2.5)
        mark("papers")
        window.swipeUp(velocity: .slow)
        pause(3.5)
        window.swipeUp(velocity: .slow)
        pause(3.5)
        window.swipeUp(velocity: .slow)
        pause(3.0)

        // Profile
        mark("profile")
        tapTab(app, "You")
        pause(4.5)
        window.swipeUp(velocity: .slow)
        pause(3.0)
        mark("about")
        tap(button(app, containing: "How Sharpy checks"))
        pause(7.0)
        tap(app.buttons["Done"])
        pause(1.2)
        mark("end")
        pause(1.0)
    }

    private func button(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func tap(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5) {
            element.tap()
        } else {
            print("TOURSKIP \(element)")
        }
    }

    private func tapTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 3) {
            tab.tap()
        } else {
            app.buttons[name].firstMatch.tap()
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func mark(_ name: String) {
        print("TOURMARK \(name) \(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
}
