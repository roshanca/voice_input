import Foundation

extension UserDefaults {
    enum Keys {
        static let selectedLanguage = "selectedLanguage"
        static let llmEnabled = "llmEnabled"
        static let llmConfigs = "llmConfigs"
        static let selectedConfigID = "selectedConfigID"
        static let copyToClipboard = "copyToClipboard"
        static let autoSend = "autoSend"
        static let autoSendOverrides = "autoSendOverrides"
        static let perAppLLMProfileOverrides = "perAppLLMProfileOverrides"
        static let interactionSounds = "interactionSounds"
        static let selectedMicUID = "selectedMicUID"
        static let dictionaryDirectReplacement = "dictionaryDirectReplacement"
        static let historyAudioEnabled = "historyAudioEnabled"
        static let dictationHotkeyBindings = "dictationHotkeyBindings"
        static let rePasteHotkeyBindings = "rePasteHotkeyBindings"
        static let translateHotkeyBindings = "translateHotkeyBindings"
        static let rewriteHotkeyBindings = "rewriteHotkeyBindings"
        static let selectionTranslateHotkeyBindings = "selectionTranslateHotkeyBindings"
        static let selectionRewriteHotkeyBindings = "selectionRewriteHotkeyBindings"
        static let addToDictionaryHotkeyBindings = "addToDictionaryHotkeyBindings"
        static let translateTargetLanguage = "translateTargetLanguage"
        static let asrProvider = "asrProvider"
        static let remoteASRBaseURL = "remoteASRBaseURL"
        static let remoteASRModel = "remoteASRModel"
        // Legacy key: single scalar hotkey, superseded by the binding list
        // above but kept in sync for downgrade compatibility.
        static let hotkeyData = "hotkeyData"
        // Legacy keys for migration
        static let legacyLLMBaseURL = "llmBaseURL"
        static let legacyLLMAPIKey = "llmAPIKey"
        static let legacyLLMModel = "llmModel"
    }

    var selectedLanguage: String {
        get { string(forKey: Keys.selectedLanguage) ?? "zh-CN" }
        set { set(newValue, forKey: Keys.selectedLanguage) }
    }

    var llmEnabled: Bool {
        get { bool(forKey: Keys.llmEnabled) }
        set { set(newValue, forKey: Keys.llmEnabled) }
    }

    var copyToClipboard: Bool {
        get { bool(forKey: Keys.copyToClipboard) }
        set { set(newValue, forKey: Keys.copyToClipboard) }
    }

    var autoSend: Bool {
        get { bool(forKey: Keys.autoSend) }
        set { set(newValue, forKey: Keys.autoSend) }
    }

    /// Per-app auto-send rules: bundle identifier → forced on/off. An app
    /// with no entry follows the global `autoSend` toggle — removing the
    /// entry is how an override returns to inherit.
    ///
    /// Entries decode independently and only true booleans are kept: one
    /// malformed value must not wipe out every valid rule (a wholesale
    /// `[String: Bool]` cast would). `as? Bool` alone is too loose — a
    /// stored `1` casts successfully — so identity is checked against the
    /// real CFBoolean type.
    var autoSendOverrides: [String: Bool] {
        get {
            guard let dict = dictionary(forKey: Keys.autoSendOverrides) else { return [:] }
            return dict.compactMapValues { value in
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
                      let bool = value as? Bool else { return nil }
                return bool
            }
        }
        set { set(newValue, forKey: Keys.autoSendOverrides) }
    }

    /// Per-app LLM profile routing: bundle identifier → profile UUID string.
    /// An app with no entry follows the global active profile — removing the
    /// entry is how an override returns to inherit.
    ///
    /// Entries decode independently and only UUID-parseable strings are
    /// kept: one malformed value must not wipe out every valid route (same
    /// contract as `autoSendOverrides`). A value that parses but names a
    /// deleted profile is *not* malformed — `LLMProfileRouting` falls back
    /// for it at resolve time.
    var perAppLLMProfileOverrides: [String: String] {
        get {
            guard let dict = dictionary(forKey: Keys.perAppLLMProfileOverrides) else { return [:] }
            return dict.compactMapValues { value in
                guard let raw = value as? String, UUID(uuidString: raw) != nil else { return nil }
                return raw
            }
        }
        set { set(newValue, forKey: Keys.perAppLLMProfileOverrides) }
    }

    var interactionSounds: Bool {
        get { bool(forKey: Keys.interactionSounds) }
        set { set(newValue, forKey: Keys.interactionSounds) }
    }

    var selectedMicUID: String? {
        get { string(forKey: Keys.selectedMicUID) }
        set { set(newValue, forKey: Keys.selectedMicUID) }
    }

    /// Defaults to true — audio capture is the point of history playback,
    /// and disk use stays bounded by HistoryStore's clip retention cap.
    /// Snapshotted at recording start, so toggling it mid-session takes
    /// effect on the next dictation.
    var historyAudioEnabled: Bool {
        get { object(forKey: Keys.historyAudioEnabled) as? Bool ?? true }
        set { set(newValue, forKey: Keys.historyAudioEnabled) }
    }

    /// Defaults to true — dictionary replacements apply directly to ASR output.
    var dictionaryDirectReplacement: Bool {
        get { object(forKey: Keys.dictionaryDirectReplacement) as? Bool ?? true }
        set { set(newValue, forKey: Keys.dictionaryDirectReplacement) }
    }

    /// Legacy accessor: raw scalar hotkey payload. Superseded by
    /// `dictationHotkeyBindings` and kept in sync with its first binding.
    var hotkeyData: Data? {
        get { data(forKey: Keys.hotkeyData) }
        set { set(newValue, forKey: Keys.hotkeyData) }
    }

    /// Dictation hotkey bindings. Reads migrate the legacy scalar `hotkeyData`
    /// into a one-element `.hold` list; writes keep `hotkeyData` in sync with
    /// the first binding so older builds still see a valid hotkey.
    var dictationHotkeyBindings: [HotkeyBinding] {
        get {
            if let data = data(forKey: Keys.dictationHotkeyBindings),
               let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            if let data = hotkeyData,
               let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data) {
                let migrated = [HotkeyBinding(hotkey: hotkey, behavior: .hold)]
                self.dictationHotkeyBindings = migrated
                return migrated
            }
            return [HotkeyBinding(hotkey: .fnKey, behavior: .hold)]
        }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: Keys.dictationHotkeyBindings)
            if let first = newValue.first {
                hotkeyData = try? JSONEncoder().encode(first.hotkey)
            }
        }
    }

    /// Re-paste chord bindings — new key, so no legacy migration. Defaults
    /// to ⌃⌘V (V = keyCode 9); the `.hold` behavior here means "act on the
    /// press edge", dispatch collapses it to one action per press.
    var rePasteHotkeyBindings: [HotkeyBinding] {
        get {
            if let data = data(forKey: Keys.rePasteHotkeyBindings),
               let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            return [HotkeyBinding(hotkey: .chord(keyCode: 9, modifiers: [.control, .command]), behavior: .hold)]
        }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: Keys.rePasteHotkeyBindings)
        }
    }

    /// Translate-mode bindings — new key, no migration. `.hold` here is real
    /// push-to-talk: the press edge starts a translate session, the release
    /// submits it. Defaults to ⌃⌥T (T = keyCode 17). The suggested ⌃⌥Space
    /// was rejected — it is macOS's own "Select next source in Input menu"
    /// shortcut, which the zh-CN user base relies on, and our tap swallows
    /// bound chords wholesale so the system shortcut would die while
    /// VoiceInput runs.
    var translateHotkeyBindings: [HotkeyBinding] {
        get {
            if let data = data(forKey: Keys.translateHotkeyBindings),
               let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            return [HotkeyBinding(hotkey: .chord(keyCode: 17, modifiers: [.control, .option]), behavior: .hold)]
        }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: Keys.translateHotkeyBindings)
        }
    }

    /// Rewrite-mode bindings — new key, no migration. `.hold` is real
    /// push-to-talk: the press starts a rewrite session, the release sends
    /// the transcript to the LLM as an instruction. Defaults to ⌃⌥R
    /// (R = keyCode 15): R-ewrite sits in the same ⌃⌥ voice family as
    /// ⌃⌥T translate — ⌃⌘ holds re-paste (V) and ⌃⇧ the selection trio.
    var rewriteHotkeyBindings: [HotkeyBinding] {
        get {
            if let data = data(forKey: Keys.rewriteHotkeyBindings),
               let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            return [HotkeyBinding(hotkey: .chord(keyCode: 15, modifiers: [.control, .option]), behavior: .hold)]
        }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: Keys.rewriteHotkeyBindings)
        }
    }

    /// The language translate sessions translate into — interpolated verbatim
    /// into the LLM prompt, so any language name works. A blank stored value
    /// falls back to English rather than producing a broken prompt.
    /// Shared by voice translate (#23) and translate-selection (#21).
    var translateTargetLanguage: String {
        get {
            let stored = string(forKey: Keys.translateTargetLanguage)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? "English" : stored
        }
        set { set(newValue, forKey: Keys.translateTargetLanguage) }
    }

    /// Selection-action chord bindings — all new keys, no legacy migration.
    /// Defaults are ⌃⇧T (translate), ⌃⇧R (rewrite), ⌃⇧D (add to
    /// dictionary): ⌃⌥ was the first pick but voice translate already owns
    /// ⌃⌥T, and ⌃⌘ already holds re-paste (⌃⌘V) — ⌃⇧ keeps the trio on one
    /// modifier family with mnemonic letters. `.hold` is load-bearing:
    /// the press probes the selection and either runs the action or falls
    /// back to hold-to-dictate, which needs the release edge to stop.
    private func selectionBindings(_ key: String, defaultChord: Hotkey) -> [HotkeyBinding] {
        if let data = data(forKey: key),
           let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return [HotkeyBinding(hotkey: defaultChord, behavior: .hold)]
    }

    private func persistSelectionBindings(_ bindings: [HotkeyBinding], key: String) {
        set(try? JSONEncoder().encode(bindings), forKey: key)
    }

    var selectionTranslateHotkeyBindings: [HotkeyBinding] {
        // T = keyCode 17.
        get { selectionBindings(Keys.selectionTranslateHotkeyBindings, defaultChord: .chord(keyCode: 17, modifiers: [.control, .shift])) }
        set { persistSelectionBindings(newValue, key: Keys.selectionTranslateHotkeyBindings) }
    }

    var selectionRewriteHotkeyBindings: [HotkeyBinding] {
        // R = keyCode 15.
        get { selectionBindings(Keys.selectionRewriteHotkeyBindings, defaultChord: .chord(keyCode: 15, modifiers: [.control, .shift])) }
        set { persistSelectionBindings(newValue, key: Keys.selectionRewriteHotkeyBindings) }
    }

    var addToDictionaryHotkeyBindings: [HotkeyBinding] {
        // D = keyCode 2.
        get { selectionBindings(Keys.addToDictionaryHotkeyBindings, defaultChord: .chord(keyCode: 2, modifiers: [.control, .shift])) }
        set { persistSelectionBindings(newValue, key: Keys.addToDictionaryHotkeyBindings) }
    }

    /// ASR backend for new sessions. Unknown/absent values read as
    /// `.system` — a corrupted default must never silently disable
    /// dictation. Snapshotted into the session at press time (#28).
    var asrProvider: ASRProvider {
        get { string(forKey: Keys.asrProvider).flatMap(ASRProvider.init(rawValue:)) ?? .system }
        set { set(newValue.rawValue, forKey: Keys.asrProvider) }
    }

    /// Remote-ASR endpoint base — the upload POSTs `{base}/audio/
    /// transcriptions`. Defaults to blank (unconfigured): an unset value
    /// must never be guessed into a host audio gets sent to. Trimming on
    /// read keeps a spaces-only field from passing the configured check.
    var remoteASRBaseURL: String {
        get { (string(forKey: Keys.remoteASRBaseURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { set(newValue, forKey: Keys.remoteASRBaseURL) }
    }

    /// Remote-ASR model (e.g. "whisper-1", "whisper-large-v3"). Blank
    /// normalizes to "whisper-1" — the API requires the field and a stored
    /// blank would just produce malformed requests.
    var remoteASRModel: String {
        get {
            let stored = (string(forKey: Keys.remoteASRModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? RemoteASRConfig.placeholderModel : stored
        }
        set { set(newValue, forKey: Keys.remoteASRModel) }
    }

    var llmConfigs: [LLMConfig] {
        get {
            guard let data = data(forKey: Keys.llmConfigs),
                  let decoded = try? JSONDecoder().decode([LLMConfig].self, from: data) else {
                // Migrate from legacy single config if present
                let legacyURL = string(forKey: Keys.legacyLLMBaseURL) ?? ""
                let legacyKey = string(forKey: Keys.legacyLLMAPIKey) ?? ""
                let legacyModel = string(forKey: Keys.legacyLLMModel) ?? "gpt-4o-mini"
                if !legacyURL.isEmpty || !legacyKey.isEmpty {
                    let migrated = LLMConfig(
                        id: UUID(),
                        name: "Default",
                        providerType: .openAICompatible,
                        baseURL: legacyURL,
                        model: legacyModel
                    )
                    if !legacyKey.isEmpty {
                        KeychainHelper.set(key: legacyKey, for: migrated.id)
                    }
                    self.llmConfigs = [migrated]
                    removeObject(forKey: Keys.legacyLLMBaseURL)
                    removeObject(forKey: Keys.legacyLLMAPIKey)
                    removeObject(forKey: Keys.legacyLLMModel)
                    return [migrated]
                }
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                set(data, forKey: Keys.llmConfigs)
            }
        }
    }

    /// One-shot migration: move any plaintext API keys still embedded in the
    /// stored configs into the Keychain, then re-encode with blanked keys.
    /// Call once at app launch.
    @discardableResult
    func migrateLLMAPIKeysToKeychain() -> Bool {
        let configs = llmConfigs
        var changed = false
        for config in configs where !config.apiKey.isEmpty {
            KeychainHelper.set(key: config.apiKey, for: config.id)
            changed = true
        }
        if changed {
            // Encoding blanks the apiKey field (see LLMConfig.encode(to:)).
            llmConfigs = configs
        }
        return changed
    }

    var selectedConfigID: UUID? {
        get {
            guard let uuidString = string(forKey: Keys.selectedConfigID) else { return nil }
            return UUID(uuidString: uuidString)
        }
        set {
            set(newValue?.uuidString, forKey: Keys.selectedConfigID)
        }
    }

    var currentLLMConfig: LLMConfig? {
        let configs = llmConfigs
        guard let selectedID = selectedConfigID,
              let config = configs.first(where: { $0.id == selectedID }) else {
            return configs.first
        }
        return config
    }
}
