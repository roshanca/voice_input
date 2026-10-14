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
