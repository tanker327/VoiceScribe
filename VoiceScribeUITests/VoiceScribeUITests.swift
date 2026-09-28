import XCTest

/// Drives the real app through the accessibility layer. These stay away from anything that
/// records audio (microphone permission) or calls a provider API (uses the user's keys).
final class VoiceScribeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Press Record or start typing"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private var editor: XCUIElement { app.textViews.firstMatch }

    /// Clicking the status text lands outside the editor, which the mouse monitor turns into
    /// resigning first responder so the bare keys and menu shortcuts work again.
    private func unfocusEditor() {
        app.staticTexts["Ready"].click()
    }

    @MainActor
    func testLaunchShowsIdleState() throws {
        XCTAssertTrue(app.buttons["Record"].exists)
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertTrue(app.staticTexts["0 words · 0 chars"].exists)
    }

    @MainActor
    func testTypingInEditorUpdatesCountsAndDoesNotTriggerBareKeys() throws {
        editor.click()
        // "a", "r" and Space are bare-key shortcuts; inside the editor they must type normally.
        editor.typeText("a r test")
        XCTAssertEqual(editor.value as? String, "a r test")
        XCTAssertTrue(app.staticTexts["3 words · 8 chars"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Stop"].exists, "typing must not start a recording")
        XCTAssertTrue(app.buttons["Refine"].exists, "content phase shows the Refine button")
    }

    @MainActor
    func testOptionCCopiesEditorText() throws {
        editor.click()
        editor.typeText("copy me")
        unfocusEditor()
        app.typeKey("c", modifierFlags: .option)
        XCTAssertTrue(app.staticTexts["Copied to clipboard ✓"].waitForExistence(timeout: 3))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copy me")
    }

    @MainActor
    func testCommandDeleteClearsEditor() throws {
        editor.click()
        editor.typeText("to be cleared")
        unfocusEditor()
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Press Record or start typing"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0 words · 0 chars"].exists)
    }

    @MainActor
    func testBareKeysWithEmptyEditorDoNothingHarmful() throws {
        // With no content, A and R are no-ops (Space would record, so it is not pressed here).
        unfocusEditor()
        app.typeKey("a", modifierFlags: [])
        app.typeKey("r", modifierFlags: [])
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists)
    }
}
