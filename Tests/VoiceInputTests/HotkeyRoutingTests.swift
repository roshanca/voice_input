import XCTest
import CoreGraphics
@testable import VoiceInput

final class HotkeyRoutingTests: XCTestCase {

    private func routedBinding(_ hotkey: Hotkey, _ behavior: HotkeyBehavior = .hold,
                               _ business: HotkeyBusiness = .dictation) -> RoutedBinding {
        RoutedBinding(business: business, binding: HotkeyBinding(hotkey: hotkey, behavior: behavior))
    }

    // MARK: - Specificity

    func testOrdinaryKeyOutranksModifierOnly() {
        let entries = [
            routedBinding(.fnKey),
            routedBinding(.fKey(5)),
            routedBinding(.rightModifier(.command)),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).first?.binding.hotkey, .fKey(5))
    }

    func testBehaviorPriorityBreaksHotkeyTie() {
        let entries = [
            routedBinding(.fnKey, .tap),
            routedBinding(.fnKey, .doubleTap),
            routedBinding(.fnKey, .hold),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).map(\.binding.behavior),
                       [.doubleTap, .hold, .tap])
    }

    func testBusinessPriorityBreaksFullTie() {
        // Dictation is currently the only business and the lowest priority;
        // the sort must still be deterministic for identical bindings.
        let entries = [routedBinding(.fnKey, .hold), routedBinding(.fnKey, .hold)]
        XCTAssertEqual(HotkeyRouting.routed(entries).count, 2)
    }

    // MARK: - Event matching

    private func flagsChanged(keyCode: Int64, flags: CGEventFlags) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
        event?.type = .flagsChanged
        event?.flags = flags
        return event
    }

    func testFnKeyMatchesFlagsChangedOnly() {
        let fn = Hotkey.fnKey
        XCTAssertTrue(fn.matches(event: flagsChanged(keyCode: 63, flags: .maskSecondaryFn)!))
        // Same event family, different keycode — note a CGEvent for Fn can
        // never be keyDown: the system always reports it as flagsChanged.
        XCTAssertFalse(fn.matches(event: flagsChanged(keyCode: 62, flags: .maskSecondaryFn)!))
    }

    func testFKeyMatchesKeyDownAndKeyUpNotFlagsChanged() {
        let f5 = Hotkey.fKey(5)
        XCTAssertTrue(f5.matches(event: CGEvent(keyboardEventSource: nil, virtualKey: 96, keyDown: true)!))
        XCTAssertTrue(f5.matches(event: CGEvent(keyboardEventSource: nil, virtualKey: 96, keyDown: false)!))
        XCTAssertFalse(f5.matches(event: flagsChanged(keyCode: 96, flags: [])!))
        XCTAssertFalse(f5.matches(event: CGEvent(keyboardEventSource: nil, virtualKey: 97, keyDown: true)!))
    }

    func testIsPressPhases() {
        XCTAssertTrue(Hotkey.fnKey.isPress(event: flagsChanged(keyCode: 63, flags: .maskSecondaryFn)!))
        XCTAssertFalse(Hotkey.fnKey.isPress(event: flagsChanged(keyCode: 63, flags: [])!))
        XCTAssertTrue(Hotkey.fKey(9).isPress(event: CGEvent(keyboardEventSource: nil, virtualKey: 101, keyDown: true)!))
        XCTAssertFalse(Hotkey.fKey(9).isPress(event: CGEvent(keyboardEventSource: nil, virtualKey: 101, keyDown: false)!))
    }

    // MARK: - Chord matching (re-paste, #19)

    private func keyEvent(keyCode: Int64, keyDown: Bool, flags: CGEventFlags = []) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        return event
    }

    /// ⌃⌘V — the persisted re-paste default (V = keyCode 9).
    private let ctrlCmdV = Hotkey.chord(keyCode: 9, modifiers: [.control, .command])

    func testChordMatchesExactModifiersOnKeyDown() {
        XCTAssertTrue(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskControl, .maskCommand])!))
    }

    func testChordRejectsWrongKeyCode() {
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 8, keyDown: true, flags: [.maskControl, .maskCommand])!))
    }

    func testChordRejectsMissingModifier() {
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskCommand])!))
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [])!))
    }

    /// Extra modifiers must not be claimed — ⌃⌘⇧V is some other app's
    /// shortcut (e.g. "paste and match style") and has to pass through.
    func testChordRejectsSupersetModifiers() {
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskControl, .maskCommand, .maskShift])!))
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskControl, .maskCommand, .maskAlternate])!))
    }

    /// Fn and Caps Lock never disambiguate a chord — a ⌃⌘V press while
    /// Caps Lock happens to be engaged still matches.
    func testChordIgnoresFnAndCapsLock() {
        let flags: CGEventFlags = [.maskControl, .maskCommand, .maskSecondaryFn, .maskAlphaShift]
        XCTAssertTrue(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: flags)!))
    }

    func testChordKeyUpMatchesOnKeyCodeAloneSoPressAlwaysCloses() {
        // Both phases match so the tap swallows the whole keystroke. keyUp
        // ignores modifiers entirely — the user may release ⌃ first or add
        // ⇧ mid-hold, and the press must still end (a dead next press is
        // worse than a swallowed keyUp the app never acts on).
        XCTAssertTrue(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: false, flags: [.maskControl, .maskCommand])!))
        XCTAssertTrue(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: false, flags: [.maskCommand])!))
        XCTAssertTrue(ctrlCmdV.matches(event: keyEvent(keyCode: 9, keyDown: false, flags: [.maskShift])!))
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 8, keyDown: false, flags: [])!))
    }

    func testChordPressIsKeyDownOnly() {
        XCTAssertTrue(ctrlCmdV.isPress(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskControl, .maskCommand])!))
        XCTAssertFalse(ctrlCmdV.isPress(event: keyEvent(keyCode: 9, keyDown: false, flags: [.maskControl, .maskCommand])!))
        XCTAssertFalse(ctrlCmdV.usesFlagsChanged)
        XCTAssertEqual(ctrlCmdV.displayName, "⌃⌘V")
    }

    func testChordOutranksBareKey() {
        let entries = [
            routedBinding(.fKey(5)),
            routedBinding(.chord(keyCode: 9, modifiers: [.control, .command])),
            routedBinding(.fnKey),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).first?.binding.hotkey,
                       .chord(keyCode: 9, modifiers: [.control, .command]))
    }

    /// Same hotkey + same behavior in both businesses: rePaste wins so a
    /// re-paste binding can shadow an identical dictation binding.
    func testRePasteBusinessOutranksDictationOnFullTie() {
        let chord = Hotkey.chord(keyCode: 9, modifiers: [.control, .command])
        let entries = [
            routedBinding(chord, .hold, .dictation),
            routedBinding(chord, .hold, .rePaste),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).first?.business, .rePaste)
    }

    /// Translate sits above dictation/rePaste on a full tie, so a translate
    /// binding shadows identical dictation/re-paste bindings (#23).
    func testTranslateBusinessOutranksDictationAndRePasteOnFullTie() {
        let chord = Hotkey.chord(keyCode: 17, modifiers: [.control, .option])
        let entries = [
            routedBinding(chord, .hold, .dictation),
            routedBinding(chord, .hold, .rePaste),
            routedBinding(chord, .hold, .translate),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).first?.business, .translate)
    }

    /// All seven businesses on the same chord + behavior: the selection
    /// actions win in translate > rewrite > dictionary order, then voice
    /// rewrite, then translate, then rePaste, and dictation stays last so
    /// anything else can preempt it (#21+#22+#23).
    func testSelectionBusinessesOutrankEverythingOnFullTie() {
        let chord = Hotkey.chord(keyCode: 9, modifiers: [.control, .command])
        let entries = [
            routedBinding(chord, .hold, .dictation),
            routedBinding(chord, .hold, .addToDictionary),
            routedBinding(chord, .hold, .rePaste),
            routedBinding(chord, .hold, .translate),
            routedBinding(chord, .hold, .rewrite),
            routedBinding(chord, .hold, .selectionRewrite),
            routedBinding(chord, .hold, .selectionTranslate),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).map(\.business),
                       [.selectionTranslate, .selectionRewrite, .addToDictionary, .rewrite, .translate, .rePaste, .dictation])
    }

    /// Rewrite sits above the other voice businesses on a full tie, so a
    /// rewrite binding shadows identical dictation/re-paste/translate
    /// bindings but still loses to the selection actions (#22).
    func testRewriteBusinessOutranksVoiceBusinessesOnFullTie() {
        let chord = Hotkey.chord(keyCode: 15, modifiers: [.control, .option])
        let entries = [
            routedBinding(chord, .hold, .dictation),
            routedBinding(chord, .hold, .rePaste),
            routedBinding(chord, .hold, .translate),
            routedBinding(chord, .hold, .rewrite),
            routedBinding(chord, .hold, .addToDictionary),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).map(\.business),
                       [.addToDictionary, .rewrite, .translate, .rePaste, .dictation])
    }

    /// Lower-priority businesses never preempt a more specific hotkey — a
    /// dictation chord still beats a translate fn binding.
    func testSpecificityStillBeatsBusinessPriority() {
        let entries = [
            routedBinding(.fnKey, .hold, .translate),
            routedBinding(.chord(keyCode: 17, modifiers: [.control, .option]), .hold, .dictation),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).first?.business, .dictation)
    }

    /// Each new business still loses to a more specific hotkey — business
    /// priority is only the last tie-breaker.
    func testSelectionBusinessDoesNotBeatMoreSpecificHotkey() {
        let entries = [
            routedBinding(.chord(keyCode: 17, modifiers: [.control, .option]), .hold, .dictation),
            routedBinding(.fnKey, .hold, .selectionTranslate),
        ]
        XCTAssertEqual(HotkeyRouting.routed(entries).first?.business, .dictation)
    }

    /// The persisted default chords must not collide: ⌃⇧T/⌃⇧R/⌃⇧D each
    /// match only their own key+modifier set — none shadow ⌃⌘V re-paste,
    /// and none fire on the ⌃⌥T voice-translate chord (#21).
    func testSelectionChordsDoNotCollideWithRePasteOrTranslate() {
        let selTranslate = Hotkey.chord(keyCode: 17, modifiers: [.control, .shift])  // T
        let rewrite = Hotkey.chord(keyCode: 15, modifiers: [.control, .shift])      // R
        let dictionary = Hotkey.chord(keyCode: 2, modifiers: [.control, .shift])    // D
        let ctrlShift: CGEventFlags = [.maskControl, .maskShift]
        let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]

        XCTAssertFalse(selTranslate.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskControl, .maskCommand])!))
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 17, keyDown: true, flags: ctrlShift)!))
        XCTAssertFalse(selTranslate.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: ctrlShift)!))
        XCTAssertFalse(rewrite.matches(event: keyEvent(keyCode: 2, keyDown: true, flags: ctrlShift)!))
        XCTAssertFalse(dictionary.matches(event: keyEvent(keyCode: 17, keyDown: true, flags: ctrlShift)!))
        // The ⌃⌥T voice-translate press must not trip any selection chord.
        XCTAssertFalse(selTranslate.matches(event: keyEvent(keyCode: 17, keyDown: true, flags: ctrlOpt)!))

        XCTAssertTrue(selTranslate.matches(event: keyEvent(keyCode: 17, keyDown: true, flags: ctrlShift)!))
        XCTAssertTrue(rewrite.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: ctrlShift)!))
        XCTAssertTrue(dictionary.matches(event: keyEvent(keyCode: 2, keyDown: true, flags: ctrlShift)!))
    }


    /// The persisted rewrite default ⌃⌥R (keyCode 15 + ⌃⌥) must not
    /// collide with the other voice/selection chords: same key but ⇧ in
    /// ⌃⇧R, same modifiers but T in ⌃⌥T — exact-match keeps them apart,
    /// and neither business shadows re-paste's ⌃⌘V (#22).
    func testRewriteChordDoesNotCollideWithOtherDefaults() {
        let rewrite = Hotkey.chord(keyCode: 15, modifiers: [.control, .option])
        let selRewrite = Hotkey.chord(keyCode: 15, modifiers: [.control, .shift])
        let translate = Hotkey.chord(keyCode: 17, modifiers: [.control, .option])
        let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]

        XCTAssertTrue(rewrite.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: ctrlOpt)!))
        // Same key with ⇧ instead of ⌥ is the selection-rewrite chord —
        // neither claims the other's events.
        XCTAssertFalse(rewrite.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: [.maskControl, .maskShift])!))
        XCTAssertFalse(selRewrite.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: ctrlOpt)!))
        // ⌃⌥R must not trip voice translate (⌃⌥T) or re-paste (⌃⌘V).
        XCTAssertFalse(translate.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: ctrlOpt)!))
        XCTAssertFalse(rewrite.matches(event: keyEvent(keyCode: 17, keyDown: true, flags: ctrlOpt)!))
        XCTAssertFalse(ctrlCmdV.matches(event: keyEvent(keyCode: 15, keyDown: true, flags: ctrlOpt)!))
        XCTAssertFalse(rewrite.matches(event: keyEvent(keyCode: 9, keyDown: true, flags: [.maskControl, .maskCommand])!))
    }

    func testChordBindingCodableRoundTrip() throws {
        let bindings = [
            HotkeyBinding(hotkey: .chord(keyCode: 9, modifiers: [.control, .command]), behavior: .hold),
            HotkeyBinding(hotkey: .chord(keyCode: 6, modifiers: [.option, .shift]), behavior: .tap),
        ]
        let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: JSONEncoder().encode(bindings))
        XCTAssertEqual(decoded, bindings)
    }

    // MARK: - Persistence / migration shapes

    func testBindingCodableRoundTrip() throws {
        let bindings = [
            HotkeyBinding(hotkey: .fnKey, behavior: .hold),
            HotkeyBinding(hotkey: .fKey(7), behavior: .tap),
            HotkeyBinding(hotkey: .rightModifier(.option), behavior: .doubleTap),
        ]
        let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: JSONEncoder().encode(bindings))
        XCTAssertEqual(decoded, bindings)
    }

    func testUnknownBehaviorDecodesAsHold() throws {
        let json = #"[{"hotkey":{"fnKey":{}},"behavior":"futureGesture"}]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: json)
        XCTAssertEqual(decoded, [HotkeyBinding(hotkey: .fnKey, behavior: .hold)])
    }

    func testLegacyScalarHotkeyStillDecodes() throws {
        // The legacy `hotkeyData` payload must keep decoding so migration can
        // read it — the enum's Codable shape is a compatibility contract.
        let data = try JSONEncoder().encode(Hotkey.fKey(9))
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: data), .fKey(9))
    }
}
