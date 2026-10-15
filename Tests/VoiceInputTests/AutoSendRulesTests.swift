import XCTest
@testable import VoiceInput

final class AutoSendRulesTests: XCTestCase {
    private let chat = "com.example.chat"
    private let editor = "com.example.editor"

    // MARK: - Rule resolution

    /// An app with no stored rule follows the global auto-send setting,
    /// whichever way it is set.
    func testUnconfiguredAppInheritsGlobal() {
        XCTAssertTrue(AutoSendRules.shouldAutoSend(bundleID: chat, overrides: [:], globalDefault: true))
        XCTAssertFalse(AutoSendRules.shouldAutoSend(bundleID: chat, overrides: [:], globalDefault: false))
    }

    /// A dictation target whose bundle ID could not be read behaves like an
    /// unconfigured app — the global setting still applies.
    func testMissingBundleIDInheritsGlobal() {
        XCTAssertTrue(AutoSendRules.shouldAutoSend(bundleID: nil, overrides: [chat: false], globalDefault: true))
        XCTAssertFalse(AutoSendRules.shouldAutoSend(bundleID: nil, overrides: [chat: true], globalDefault: false))
    }

    /// An override only applies to its own app — rules for other apps must
    /// not leak into this app's resolution.
    func testOtherAppsRulesDoNotApply() {
        XCTAssertTrue(AutoSendRules.shouldAutoSend(
            bundleID: chat,
            overrides: [editor: false],
            globalDefault: true
        ))
    }

    /// A per-app "on" rule forces auto-send even when the global setting
    /// is off — the chat-app case the feature exists for.
    func testOverrideOnForcesSendWithGlobalOff() {
        XCTAssertTrue(AutoSendRules.shouldAutoSend(
            bundleID: chat,
            overrides: [chat: true],
            globalDefault: false
        ))
    }

    /// A per-app "off" rule suppresses auto-send even when the global
    /// setting is on — the editor case.
    func testOverrideOffSuppressesSendWithGlobalOn() {
        XCTAssertFalse(AutoSendRules.shouldAutoSend(
            bundleID: editor,
            overrides: [editor: false],
            globalDefault: true
        ))
    }

    /// Overrides agree with the global setting without changing it.
    func testOverrideMatchingGlobalKeepsDecision() {
        XCTAssertTrue(AutoSendRules.shouldAutoSend(bundleID: chat, overrides: [chat: true], globalDefault: true))
        XCTAssertFalse(AutoSendRules.shouldAutoSend(bundleID: chat, overrides: [chat: false], globalDefault: false))
    }

    /// Different apps can hold opposite rules at the same time.
    func testPerAppRulesAreIndependent() {
        let overrides = [chat: true, editor: false]
        XCTAssertTrue(AutoSendRules.shouldAutoSend(bundleID: chat, overrides: overrides, globalDefault: false))
        XCTAssertFalse(AutoSendRules.shouldAutoSend(bundleID: editor, overrides: overrides, globalDefault: false))
    }

    // MARK: - Override lookup

    /// Inherit is reported for apps without a stored entry — it is a lookup
    /// result, never a stored value.
    func testLookupReportsInheritWithoutEntry() {
        XCTAssertEqual(AutoSendRules.override(for: chat, in: [:]), .inherit)
        XCTAssertEqual(AutoSendRules.override(for: nil, in: [chat: true]), .inherit)
    }

    func testLookupReportsStoredRule() {
        XCTAssertEqual(AutoSendRules.override(for: chat, in: [chat: true]), .on)
        XCTAssertEqual(AutoSendRules.override(for: chat, in: [chat: false]), .off)
    }

    // MARK: - Persistence

    /// Overrides round-trip through UserDefaults as a bundle-ID → Bool
    /// dictionary; deleting an entry is what restores inheritance. Uses a
    /// dedicated suite so the test never touches the app's real defaults.
    func testOverridesRoundTripThroughUserDefaults() throws {
        let suiteName = "AutoSendRulesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(defaults.autoSendOverrides, [:])
        XCTAssertEqual(AutoSendRules.override(for: chat, in: defaults.autoSendOverrides), .inherit)

        defaults.autoSendOverrides = [chat: true, editor: false]
        let restored = UserDefaults(suiteName: suiteName)
        XCTAssertEqual(restored?.autoSendOverrides, [chat: true, editor: false])
        XCTAssertTrue(AutoSendRules.shouldAutoSend(
            bundleID: chat,
            overrides: restored?.autoSendOverrides ?? [:],
            globalDefault: false
        ))

        var overrides = defaults.autoSendOverrides
        overrides.removeValue(forKey: chat)
        defaults.autoSendOverrides = overrides
        XCTAssertEqual(AutoSendRules.override(for: chat, in: defaults.autoSendOverrides), .inherit)
        XCTAssertEqual(AutoSendRules.override(for: editor, in: defaults.autoSendOverrides), .off)
    }
}
