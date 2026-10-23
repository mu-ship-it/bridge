import XCTest

/// Not part of the Bridge scheme's tests: run through the WidgetShots scheme to put the board
/// widgets on a simulator's home screen for screenshots. Needs BOARD_URL and BOARD_TOKEN in the
/// environment (xcodebuild: TEST_RUNNER_BOARD_URL=… TEST_RUNNER_BOARD_TOKEN=…) and a box
/// serving a board under `muster`. Leaves the home screen in edit-free state for `simctl io`.
@MainActor
final class WidgetShotsUITests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testBoardWidgetsOnHomeScreen() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["BOARD_URL"], "set TEST_RUNNER_BOARD_URL")
        let token = try XCTUnwrap(env["BOARD_TOKEN"], "set TEST_RUNNER_BOARD_TOKEN")
        let sizes = (env["BOARD_SIZES"] ?? "Medium,Large").split(separator: ",").map(String.init)

        configureApp(url: url, token: token)
        clearFirstPage()
        // Added in reverse: each new widget lands at the top of the page. One long press on an
        // empty spot; the home screen stays in edit mode between adds.
        springboard.press(forDuration: 2)
        for size in sizes.reversed() { try addBoardWidget(size: size) }
        springboard.buttons["Done"].firstMatch.tap()
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(3)
    }

    /// Back to the first home screen page, for a screenshot.
    func testHomeFirstPage() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    private func configureApp(url: String, token: String) {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        let urlField = app.textFields.element(boundBy: 0)
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        replace(urlField, with: url)
        replace(app.textFields.element(boundBy: 1), with: "sim-shots")
        let tokenField = app.secureTextFields.firstMatch
        tokenField.tap()
        tokenField.typeText(token + "\n")
        let save = app.buttons["SAVE"]
        if !save.waitForExistence(timeout: 2) { app.swipeUp() }
        save.tap()
        sleep(1)
        app.terminate()
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        // An empty field reports its placeholder as its value: delete either way.
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5))
        field.typeText(text)
    }

    /// Back to page one and remove every widget there, so the board widgets have the room.
    private func clearFirstPage() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(1)
        springboard.press(forDuration: 2)
        for _ in 0..<12 {
            let widget = springboard.icons.matching(NSPredicate(format: "value BEGINSWITH 'Widget'")).firstMatch
            guard widget.exists, widget.frame.minX >= 0, widget.frame.maxX <= springboard.frame.maxX else { break }
            widget.buttons["DeleteButton"].tap()
            let remove = springboard.alerts.buttons["Remove"]
            if remove.waitForExistence(timeout: 3) { remove.tap() } else { break }
            sleep(1)
        }
        springboard.buttons["Done"].firstMatch.tap()
        sleep(1)
    }

    private func addBoardWidget(size: String) throws {
        springboard.buttons["Edit"].firstMatch.tap()
        let add = springboard.buttons["Add Widget"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let search = springboard.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("白手套")
        let cell = springboard.cells["白手套"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.tap()
        sleep(1)

        // The gallery labels small…large previews "Widget, <size>"; extra large is plain "Widget".
        let board = size == "Extra Large"
            ? NSPredicate(format: "label CONTAINS '看板' AND value == 'Widget'")
            : NSPredicate(format: "label CONTAINS '看板' AND value CONTAINS[c] %@", ", \(size)")
        var found = false
        for _ in 0..<10 {
            let candidate = springboard.buttons.matching(board).firstMatch
            // On screen, not merely in the paged scroll view (an Extra Large preview is never "hittable").
            if candidate.exists, candidate.frame.midX > 0, candidate.frame.midX < springboard.frame.width {
                found = true
                break
            }
            // The gallery's page dots ("page 1 of 5"; the home screen's say "Page"): tap right of them.
            let dots = springboard.pageIndicators.matching(NSPredicate(format: "value BEGINSWITH 'page '")).firstMatch
            dots.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            sleep(1)
        }
        XCTAssertTrue(found, "no Board widget of size \(size) in the gallery")
        springboard.buttons[" Add Widget"].firstMatch.tap()
        sleep(2)
    }
}
