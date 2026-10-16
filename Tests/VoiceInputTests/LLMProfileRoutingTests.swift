import XCTest
@testable import VoiceInput

final class LLMProfileRoutingTests: XCTestCase {
    private let chat = "com.example.chat"
    private let editor = "com.example.editor"

    private func config(_ name: String) -> LLMConfig {
        LLMConfig(id: UUID(), name: name, providerType: .ollama,
                  baseURL: "http://localhost:11434/v1", model: "llama3.1")
    }

    // MARK: - Rule resolution

    /// An app with no stored route uses the global pick — the selected
    /// profile when the selection resolves.
    func testUnconfiguredAppFallsBackToSelectedProfile() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: chat, overrides: [:], configs: [a, b], fallbackID: b.id
        )
        XCTAssertEqual(resolved?.id, b.id)
    }

    /// A dictation target whose bundle ID could not be read behaves like an
    /// unconfigured app — the global pick still applies.
    func testMissingBundleIDFallsBack() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: nil, overrides: [chat: b.id.uuidString], configs: [a, b], fallbackID: a.id
        )
        XCTAssertEqual(resolved?.id, a.id)
    }

    /// The stored override wins over the global selection — the whole point
    /// of the feature: a chat app refines on its own profile while the rest
    /// of the system follows the active one.
    func testExactMatchWinsOverGlobalSelection() {
        let global = config("Global"), casual = config("Casual")
        let resolved = LLMProfileRouting.resolve(
            bundleID: chat,
            overrides: [chat: casual.id.uuidString],
            configs: [global, casual],
            fallbackID: global.id
        )
        XCTAssertEqual(resolved?.id, casual.id)
    }

    /// An override only applies to its own app — rules for other apps must
    /// not leak into this app's resolution.
    func testOtherAppsRoutesDoNotApply() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: editor,
            overrides: [chat: b.id.uuidString],
            configs: [a, b],
            fallbackID: a.id
        )
        XCTAssertEqual(resolved?.id, a.id)
    }

    /// An override naming a profile that was deleted falls back to the
    /// global pick rather than pinning the session to a dead config.
    func testDanglingOverrideFallsBack() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: chat,
            overrides: [chat: UUID().uuidString],
            configs: [a, b],
            fallbackID: b.id
        )
        XCTAssertEqual(resolved?.id, b.id)
    }

    /// A stored value that isn't a UUID at all can't route — it reads as no
    /// override. The UserDefaults accessor filters these too, but the
    /// resolver must not trust its input map.
    func testMalformedOverrideValueFallsBack() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: chat,
            overrides: [chat: "not-a-uuid"],
            configs: [a, b],
            fallbackID: b.id
        )
        XCTAssertEqual(resolved?.id, b.id)
    }

    /// With no selected id the fallback is the first profile — the same
    /// semantics `currentLLMConfig` documents.
    func testNilFallbackIDResolvesToFirstProfile() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: chat, overrides: [:], configs: [a, b], fallbackID: nil
        )
        XCTAssertEqual(resolved?.id, a.id)
    }

    /// A stale selected id (profile deleted without updating the selection)
    /// falls through to the first profile, matching `currentLLMConfig`.
    func testDanglingFallbackIDResolvesToFirstProfile() {
        let a = config("A"), b = config("B")
        let resolved = LLMProfileRouting.resolve(
            bundleID: chat, overrides: [:], configs: [a, b], fallbackID: UUID()
        )
        XCTAssertEqual(resolved?.id, a.id)
    }

    /// No profiles at all resolves to nil — the refiner's configured check
    /// treats nil as unconfigured, so dictation goes straight to insertion.
    func testNoProfilesResolvesToNil() {
        XCTAssertNil(LLMProfileRouting.resolve(
            bundleID: chat, overrides: [chat: UUID().uuidString], configs: [], fallbackID: nil
        ))
    }

    // MARK: - Override lookup

    /// No override is reported for apps without a stored entry — it is a
    /// lookup result, never a stored value.
    func testLookupReportsNilWithoutEntry() {
        XCTAssertNil(LLMProfileRouting.overrideConfigID(for: chat, in: [:]))
        XCTAssertNil(LLMProfileRouting.overrideConfigID(for: nil, in: [chat: UUID().uuidString]))
    }

    func testLookupReportsStoredID() {
        let id = UUID()
        XCTAssertEqual(LLMProfileRouting.overrideConfigID(for: chat, in: [chat: id.uuidString]), id)
    }

    // MARK: - Persistence

    /// Routes round-trip through UserDefaults as a bundle-ID → UUID-string
    /// dictionary; deleting an entry is what restores the global profile.
    /// Uses a dedicated suite so the test never touches the app's real
    /// defaults.
    func testOverridesRoundTripThroughUserDefaults() throws {
        let suiteName = "LLMProfileRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(defaults.perAppLLMProfileOverrides, [:])
        XCTAssertNil(LLMProfileRouting.overrideConfigID(for: chat, in: defaults.perAppLLMProfileOverrides))

        let casualID = UUID()
        defaults.perAppLLMProfileOverrides = [chat: casualID.uuidString]
        let restored = UserDefaults(suiteName: suiteName)
        XCTAssertEqual(restored?.perAppLLMProfileOverrides, [chat: casualID.uuidString])
        XCTAssertEqual(
            LLMProfileRouting.overrideConfigID(for: chat, in: restored?.perAppLLMProfileOverrides ?? [:]),
            casualID
        )

        var overrides = defaults.perAppLLMProfileOverrides
        overrides.removeValue(forKey: chat)
        defaults.perAppLLMProfileOverrides = overrides
        XCTAssertNil(LLMProfileRouting.overrideConfigID(for: chat, in: defaults.perAppLLMProfileOverrides))
    }

    /// Entries decode independently: a malformed value sitting next to real
    /// routes must not wipe the whole map — a wholesale `[String: String]`
    /// cast would have dropped or reinterpreted everything.
    func testMalformedEntriesDoNotDisableValidRoutes() throws {
        let suiteName = "LLMProfileRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let valid = UUID().uuidString
        defaults.set(
            [
                chat: valid,
                "com.example.broken": "garbage",
                "com.example.number": 42,
            ],
            forKey: UserDefaults.Keys.perAppLLMProfileOverrides
        )

        XCTAssertEqual(defaults.perAppLLMProfileOverrides, [chat: valid])
    }

    /// A value at the key that isn't a dictionary at all reads as empty —
    /// every app follows the global profile.
    func testNonDictionaryValueReadsAsEmpty() throws {
        let suiteName = "LLMProfileRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not a dictionary", forKey: UserDefaults.Keys.perAppLLMProfileOverrides)

        XCTAssertEqual(defaults.perAppLLMProfileOverrides, [:])
        let a = config("A")
        XCTAssertEqual(LLMProfileRouting.resolve(
            bundleID: chat,
            overrides: defaults.perAppLLMProfileOverrides,
            configs: [a],
            fallbackID: nil
        )?.id, a.id)
    }
}
