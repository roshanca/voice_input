import Carbon
import Foundation

@MainActor
final class InputMethodManager {
    static let shared = InputMethodManager()

    func isCJKInputMethod() -> Bool {
        guard let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return false
        }
        return isCJK(source: currentSource)
    }

    func currentSource() -> TISInputSource? {
        return TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    func selectASCIIInputMethod() {
        let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            if sourceID == "com.apple.keylayout.ABC" || sourceID == "com.apple.keylayout.US" {
                TISSelectInputSource(source)
                break
            }
        }
    }

    func restoreInputSource(_ source: TISInputSource?) {
        guard let source else { return }
        TISSelectInputSource(source)
    }

    private func isCJK(source: TISInputSource) -> Bool {
        guard let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return false
        }
        let languages = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String] ?? []
        return languages.contains { lang in
            lang.hasPrefix("zh") || lang.hasPrefix("ja") || lang.hasPrefix("ko")
        }
    }
}
