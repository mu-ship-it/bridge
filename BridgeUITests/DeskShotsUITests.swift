import XCTest

/// Not part of the Bridge scheme's tests: run through the WidgetShots scheme to put the desk
/// display on a simulator for `simctl io` screenshots. Needs BOARD_URL and BOARD_TOKEN like the
/// widget shots. Holds each orientation for HOLD seconds (default 20) and touches
/// `<SHOT_MARKER>-portrait` / `-landscape` when it is ready, so a script can shoot on cue.
extension WidgetShotsUITests {
    func testDeskOnScreen() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["BOARD_URL"], "set TEST_RUNNER_BOARD_URL")
        let token = try XCTUnwrap(env["BOARD_TOKEN"], "set TEST_RUNNER_BOARD_TOKEN")
        let hold = UInt32(env["HOLD"] ?? "20") ?? 20
        configureApp(url: url, token: token)

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        let open = app.buttons["OPEN DESK"]
        for _ in 0..<4 where !open.isHittable { app.swipeUp() }
        open.tap()
        sleep(5)
        for orientation in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation.1
            sleep(3)
            if let marker = env["SHOT_MARKER"] {
                FileManager.default.createFile(atPath: "\(marker)-\(orientation.0)", contents: nil)
            }
            sleep(hold)
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
