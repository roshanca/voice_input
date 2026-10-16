import XCTest
@testable import VoiceInput

/// Exercises the UserDefaults key accessors against an isolated suite so the
/// app's real preferences are never touched.
final class UserDefaultsKeysTests: XCTestCase {
    func testSelectedLanguageDefaultsToSimplifiedChinese() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.selectedLanguage, "zh-CN")
        isolated.defaults.selectedLanguage = "en-US"
        XCTAssertEqual(isolated.defaults.selectedLanguage, "en-US")
    }

    func testDictionaryDirectReplacementDefaultsToTrue() {
        let isolated = IsolatedDefaults()
        XCTAssertTrue(isolated.defaults.dictionaryDirectReplacement)
        isolated.defaults.dictionaryDirectReplacement = false
        XCTAssertFalse(isolated.defaults.dictionaryDirectReplacement)
    }

    /// Audio capture ships enabled (#25) — it's the point of history
    /// playback, and the newest-100 clip cap keeps disk use bounded.
    func testHistoryAudioEnabledDefaultsToTrue() {
        let isolated = IsolatedDefaults()
        XCTAssertTrue(isolated.defaults.historyAudioEnabled)
        isolated.defaults.historyAudioEnabled = false
        XCTAssertFalse(isolated.defaults.historyAudioEnabled)
    }

    func testBooleanFlagsDefaultToFalse() {
        let isolated = IsolatedDefaults()
        XCTAssertFalse(isolated.defaults.llmEnabled)
        XCTAssertFalse(isolated.defaults.copyToClipboard)
        XCTAssertFalse(isolated.defaults.autoSend)
        XCTAssertFalse(isolated.defaults.interactionSounds)
        XCTAssertNil(isolated.defaults.selectedMicUID)
        XCTAssertNil(isolated.defaults.hotkeyData)
    }

    func testSelectedConfigIDRoundTrip() {
        let isolated = IsolatedDefaults()
        XCTAssertNil(isolated.defaults.selectedConfigID)
        let id = UUID()
        isolated.defaults.selectedConfigID = id
        XCTAssertEqual(isolated.defaults.selectedConfigID, id)
        isolated.defaults.selectedConfigID = nil
        XCTAssertNil(isolated.defaults.selectedConfigID)
    }

    func testCurrentLLMConfigNilWhenNoProfiles() {
        let isolated = IsolatedDefaults()
        XCTAssertNil(isolated.defaults.currentLLMConfig)
    }

    func testLLMConfigsRoundTripBlanksAPIKey() {
        let isolated = IsolatedDefaults()
        let config = LLMConfig(
            id: UUID(), name: "Local", providerType: .ollama,
            baseURL: "http://localhost:11434/v1", apiKey: "secret", model: "llama3.1"
        )
        isolated.defaults.llmConfigs = [config]
        let decoded = isolated.defaults.llmConfigs
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, config.id)
        // The API key is never persisted — it lives in the Keychain.
        XCTAssertEqual(decoded.first?.apiKey, "")
    }

    /// The re-paste feature ships with ⌃⌘V as its persisted default — a
    /// brand-new install must decode exactly that binding (#19).
    func testRePasteHotkeyBindingsDefaultsToCtrlCmdV() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.rePasteHotkeyBindings,
                       [HotkeyBinding(hotkey: .chord(keyCode: 9, modifiers: [.control, .command]), behavior: .hold)])
    }

    func testRePasteHotkeyBindingsRoundTrip() {
        let isolated = IsolatedDefaults()
        let custom = [HotkeyBinding(hotkey: .chord(keyCode: 8, modifiers: [.control, .option]), behavior: .hold)]
        isolated.defaults.rePasteHotkeyBindings = custom
        XCTAssertEqual(isolated.defaults.rePasteHotkeyBindings, custom)
    }

    /// A corrupted or empty stored payload falls back to the ⌃⌘V default
    /// rather than silently disabling the feature.
    func testRePasteHotkeyBindingsFallsBackOnEmptyPayload() {
        let isolated = IsolatedDefaults()
        isolated.defaults.set(Data("[]".utf8), forKey: "rePasteHotkeyBindings")
        XCTAssertEqual(isolated.defaults.rePasteHotkeyBindings.first?.hotkey,
                       .chord(keyCode: 9, modifiers: [.control, .command]))
    }

    /// The rewrite feature ships with ⌃⌥R as its persisted default — a
    /// brand-new install must decode exactly that binding (#22). The ⌃⌥
    /// voice family pairs it with ⌃⌥T translate; ⌃⌘/⌃⇧ are taken.
    func testRewriteHotkeyBindingsDefaultsToCtrlOptR() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.rewriteHotkeyBindings,
                       [HotkeyBinding(hotkey: .chord(keyCode: 15, modifiers: [.control, .option]), behavior: .hold)])
    }

    func testRewriteHotkeyBindingsRoundTrip() {
        let isolated = IsolatedDefaults()
        let custom = [HotkeyBinding(hotkey: .chord(keyCode: 8, modifiers: [.control, .option]), behavior: .tap)]
        isolated.defaults.rewriteHotkeyBindings = custom
        XCTAssertEqual(isolated.defaults.rewriteHotkeyBindings, custom)
    }

    /// A corrupted or empty stored payload falls back to the ⌃⌥R default
    /// rather than silently disabling rewrite.
    func testRewriteHotkeyBindingsFallsBackOnEmptyPayload() {
        let isolated = IsolatedDefaults()
        isolated.defaults.set(Data("[]".utf8), forKey: "rewriteHotkeyBindings")
        XCTAssertEqual(isolated.defaults.rewriteHotkeyBindings.first?.hotkey,
                       .chord(keyCode: 15, modifiers: [.control, .option]))
    }

    /// The translate feature ships with ⌃⌥T as its persisted default — a
    /// brand-new install must decode exactly that binding (#23).
    func testTranslateHotkeyBindingsDefaultsToCtrlOptT() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.translateHotkeyBindings,
                       [HotkeyBinding(hotkey: .chord(keyCode: 17, modifiers: [.control, .option]), behavior: .hold)])
    }

    func testTranslateHotkeyBindingsRoundTrip() {
        let isolated = IsolatedDefaults()
        let custom = [HotkeyBinding(hotkey: .chord(keyCode: 8, modifiers: [.control, .option]), behavior: .hold)]
        isolated.defaults.translateHotkeyBindings = custom
        XCTAssertEqual(isolated.defaults.translateHotkeyBindings, custom)
    }

    /// A corrupted or empty stored payload falls back to the ⌃⌥T default
    /// rather than silently disabling translate.
    func testTranslateHotkeyBindingsFallsBackOnEmptyPayload() {
        let isolated = IsolatedDefaults()
        isolated.defaults.set(Data("[]".utf8), forKey: "translateHotkeyBindings")
        XCTAssertEqual(isolated.defaults.translateHotkeyBindings.first?.hotkey,
                       .chord(keyCode: 17, modifiers: [.control, .option]))
    }

    /// Default target is English; a blank stored value normalizes back to
    /// English rather than producing a broken prompt (#23, shared by #21).
    func testTranslateTargetLanguageDefaultsAndNormalizesBlank() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.translateTargetLanguage, "English")
        isolated.defaults.translateTargetLanguage = "French"
        XCTAssertEqual(isolated.defaults.translateTargetLanguage, "French")
    }

    /// The selection actions ship with ⌃⇧T/⌃⇧R/⌃⇧D persisted defaults —
    /// a brand-new install must decode exactly those bindings (#21). ⌃⌥T
    /// was already taken by voice translate, so the family moved to ⌃⇧.
    func testSelectionHotkeyBindingsDefaults() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.selectionTranslateHotkeyBindings,
                       [HotkeyBinding(hotkey: .chord(keyCode: 17, modifiers: [.control, .shift]), behavior: .hold)])
        XCTAssertEqual(isolated.defaults.selectionRewriteHotkeyBindings,
                       [HotkeyBinding(hotkey: .chord(keyCode: 15, modifiers: [.control, .shift]), behavior: .hold)])
        XCTAssertEqual(isolated.defaults.addToDictionaryHotkeyBindings,
                       [HotkeyBinding(hotkey: .chord(keyCode: 2, modifiers: [.control, .shift]), behavior: .hold)])
    }

    func testSelectionHotkeyBindingsRoundTrip() {
        let isolated = IsolatedDefaults()
        let custom = [HotkeyBinding(hotkey: .chord(keyCode: 12, modifiers: [.control, .option, .shift]), behavior: .hold)]
        isolated.defaults.selectionTranslateHotkeyBindings = custom
        isolated.defaults.selectionRewriteHotkeyBindings = custom
        isolated.defaults.addToDictionaryHotkeyBindings = custom
        XCTAssertEqual(isolated.defaults.selectionTranslateHotkeyBindings, custom)
        XCTAssertEqual(isolated.defaults.selectionRewriteHotkeyBindings, custom)
        XCTAssertEqual(isolated.defaults.addToDictionaryHotkeyBindings, custom)
    }

    /// A corrupted payload falls back to the default chord rather than
    /// silently disabling the action.
    func testSelectionHotkeyBindingsFallBackOnEmptyPayload() {
        let isolated = IsolatedDefaults()
        isolated.defaults.set(Data("[]".utf8), forKey: "selectionTranslateHotkeyBindings")
        XCTAssertEqual(isolated.defaults.selectionTranslateHotkeyBindings.first?.hotkey,
                       .chord(keyCode: 17, modifiers: [.control, .shift]))
    }

    func testTranslateTargetLanguageDefaultsAndRoundTrip() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.translateTargetLanguage, "English")
        isolated.defaults.translateTargetLanguage = "日本語"
        XCTAssertEqual(isolated.defaults.translateTargetLanguage, "日本語")
    }

    /// A blank stored value would produce an instructionless prompt — the
    /// accessor must fall back instead.
    func testTranslateTargetLanguageBlankFallsBackToEnglish() {
        let isolated = IsolatedDefaults()
        isolated.defaults.translateTargetLanguage = "   "
        XCTAssertEqual(isolated.defaults.translateTargetLanguage, "English")
    }

    /// The voice end command ships enabled (#26) — it's the feature's
    /// hands-free completion path, not an opt-in.
    func testVoiceEndCommandEnabledDefaultsToTrue() {
        let isolated = IsolatedDefaults()
        XCTAssertTrue(isolated.defaults.voiceEndCommandEnabled)
        isolated.defaults.voiceEndCommandEnabled = false
        XCTAssertFalse(isolated.defaults.voiceEndCommandEnabled)
    }

    /// Default triggers are the conservative EN+CN pair "over,完毕" — and
    /// a blank stored value restores the default rather than silently
    /// disabling the command.
    func testVoiceEndCommandPhrasesDefaultsAndNormalizesBlank() {
        let isolated = IsolatedDefaults()
        XCTAssertEqual(isolated.defaults.voiceEndCommandPhrases, "over,完毕")
        isolated.defaults.voiceEndCommandPhrases = "done,完了"
        XCTAssertEqual(isolated.defaults.voiceEndCommandPhrases, "done,完了")
        isolated.defaults.voiceEndCommandPhrases = "   "
        XCTAssertEqual(isolated.defaults.voiceEndCommandPhrases, "over,完毕")
    }

    func testCurrentLLMConfigFallsBackToFirstAndSelectsByID() {
        let isolated = IsolatedDefaults()
        let first = LLMConfig(id: UUID(), name: "A", providerType: .ollama,
                              baseURL: "http://a", model: "m1")
        let second = LLMConfig(id: UUID(), name: "B", providerType: .openAICompatible,
                               baseURL: "http://b", model: "m2")
        isolated.defaults.llmConfigs = [first, second]

        XCTAssertEqual(isolated.defaults.currentLLMConfig?.id, first.id)
        isolated.defaults.selectedConfigID = second.id
        XCTAssertEqual(isolated.defaults.currentLLMConfig?.id, second.id)
    }
}
