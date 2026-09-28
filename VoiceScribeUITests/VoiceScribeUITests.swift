import XCTest

/// Drives the real app through the accessibility layer. These stay away from anything that
/// records audio (microphone permission) or calls a provider API (uses the user's keys).
final class VoiceScribeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Press Record or double-click to type"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private var editor: XCUIElement { app.textViews.firstMatch }

    /// The editor is read-only until it is double-clicked.
    private func startEditing() {
        editor.doubleClick()
        XCTAssertTrue(app.staticTexts["Editing · Esc to finish"].waitForExistence(timeout: 3))
    }

    /// Clicking the status text lands outside the editor. The mouse monitor turns that into
    /// resigning first responder, which ends edit mode so bare keys and menu shortcuts work again.
    private func clickOutsideEditor() {
        let editing = app.staticTexts["Editing · Esc to finish"]
        (editing.exists ? editing : app.staticTexts["Ready"]).click()
    }

    @MainActor
    func testLaunchShowsIdleState() throws {
        XCTAssertTrue(app.buttons["Record"].exists)
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertTrue(app.staticTexts["0 words · 0 chars"].exists)
    }

    @MainActor
    func testSingleClickKeepsEditorReadOnly() throws {
        editor.click()
        // None of these are shortcuts, so with a writable editor they would be typed.
        app.typeText("xyz")
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertTrue(app.staticTexts["Press Record or double-click to type"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists, "a single click must not enter edit mode")
    }

    @MainActor
    func testDoubleClickEnablesTypingWithoutTriggeringBareKeys() throws {
        startEditing()
        // "a", "r" and Space are bare-key shortcuts; in edit mode they must type normally.
        editor.typeText("a r test")
        XCTAssertEqual(editor.value as? String, "a r test")
        XCTAssertTrue(app.staticTexts["3 words · 8 chars"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Stop"].exists, "typing must not start a recording")
        XCTAssertTrue(app.buttons["Refine"].exists, "content phase shows the Refine button")
    }

    @MainActor
    func testEscapeLeavesEditModeAndRestoresShortcuts() throws {
        startEditing()
        editor.typeText("hello")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 3), "Escape ends edit mode")

        app.typeText("xyz")
        XCTAssertEqual(editor.value as? String, "hello", "the editor is read-only again")

        app.typeKey("c", modifierFlags: .option)
        XCTAssertTrue(app.staticTexts["Copied to clipboard ✓"].waitForExistence(timeout: 3))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
    }

    @MainActor
    func testOptionCCopiesEditorText() throws {
        startEditing()
        editor.typeText("copy me")
        clickOutsideEditor()
        app.typeKey("c", modifierFlags: .option)
        XCTAssertTrue(app.staticTexts["Copied to clipboard ✓"].waitForExistence(timeout: 3))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copy me")
    }

    @MainActor
    func testCommandDeleteClearsEditor() throws {
        startEditing()
        editor.typeText("to be cleared")
        clickOutsideEditor()
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Press Record or double-click to type"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0 words · 0 chars"].exists)
    }

    @MainActor
    func testCommandDeleteWhileEditingClearsAndLeavesEditMode() throws {
        startEditing()
        editor.typeText("to be cleared")
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Press Record or double-click to type"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertTrue(app.staticTexts["Ready"].exists, "Clear leaves edit mode so Space records right away")
    }

    @MainActor
    func testUndoWorksWhileEditing() throws {
        startEditing()
        editor.typeText("undo me")
        XCTAssertEqual(editor.value as? String, "undo me")
        app.typeKey("z", modifierFlags: .command)
        // Typing may be coalesced into one or several undo groups; either way the text shrinks.
        let afterUndo = editor.value as? String ?? "undo me"
        XCTAssertNotEqual(afterUndo, "undo me", "⌘Z must reach the editor's own undo manager")
        XCTAssertTrue("undo me".hasPrefix(afterUndo))
    }

    @MainActor
    func testBareKeysWithEmptyEditorDoNothingHarmful() throws {
        // With no content, A and R are no-ops (Space would record, so it is not pressed here).
        clickOutsideEditor()
        app.typeKey("a", modifierFlags: [])
        app.typeKey("r", modifierFlags: [])
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists)
    }
}
