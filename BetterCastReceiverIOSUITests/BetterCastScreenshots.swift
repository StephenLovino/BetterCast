import XCTest

/// UI test that navigates through all tabs and takes App Store screenshots.
/// Run with: xcodebuild test -project BetterCastReceiverIOS.xcodeproj -scheme BetterCastReceiverIOSUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
final class BetterCastScreenshots: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    func testTakeScreenshots() throws {
        // Wait for app to settle
        sleep(2)

        // Set onboarding completed so we land on the main tabs
        app.launchArguments = ["UI_TESTING", "-hasCompletedOnboarding", "YES"]

        // Screenshot 1: Connect tab (receiver waiting for sender)
        takeScreenshot(name: "01_connect_waiting")

        // Switch to Setup tab
        app.tabBars.buttons["Setup"].tap()
        sleep(1)
        takeScreenshot(name: "02_setup_guide")

        // Switch to Settings tab
        app.tabBars.buttons["Settings"].tap()
        sleep(1)
        takeScreenshot(name: "03_settings")

        // Switch back to Connect for a "connected" state screenshot
        app.tabBars.buttons["Connect"].tap()
        sleep(1)
    }

    private func takeScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
