import Foundation

/// Turns a matched hotkey's press/release edges into gesture decisions for
/// the non-hold behaviors (`tap` = press-release toggles, `doubleTap` = two
/// rapid cycles toggle). Pure logic — the event tap mutates one `State` per
/// binding inside its callback; tests drive it with synthetic timestamps.
enum GestureRouting {
    /// One edge of a matched hotkey event, from `Hotkey.isPress`.
    enum Edge {
        case press
        case release
    }

    /// What the tap does with the edge.
    enum Action: Equatable {
        /// Swallow the edge, no callback.
        case consume
        /// Swallow the edge and fire the toggle.
        case consumeAndToggle
        /// Belongs to a press the tap never claimed (e.g. the key was held
        /// before the binding existed) — let the focused app have it, the
        /// same "never deliver half a keystroke" rule as EscapeRouting.
        case passThrough
    }

    /// Per-binding gesture state, mutated only inside the tap callback.
    struct State: Equatable {
        /// A press edge is in flight. Held keys can emit repeat press edges
        /// (fKey auto-repeat, stray flagsChanged) — only the first counts.
        var pressed = false
        /// When the first press of a candidate double-tap pair landed.
        /// `nil` while no unpaired press is pending.
        var pendingPressAt: TimeInterval?
    }

    /// Decide one edge. `now` is seconds since boot (the tap passes
    /// `ProcessInfo.systemUptime`); `doubleTapInterval` is the system
    /// double-click window mirrored onto a nonisolated static at update time.
    nonisolated static func action(
        edge: Edge,
        behavior: HotkeyBehavior,
        now: TimeInterval,
        doubleTapInterval: TimeInterval,
        state: inout State
    ) -> Action {
        switch behavior {
        case .hold:
            // Hold edges are dispatched directly by the tap and never reach
            // here — consume so a stray call can't leak a bound key.
            return .consume
        case .tap:
            switch edge {
            case .press:
                // Whether fresh or a repeat, the edge is swallowed; firing
                // waits for the release so a complete cycle is one toggle
                // (Voxt precedent — the downstroke alone must not commit).
                state.pressed = true
                return .consume
            case .release:
                guard state.pressed else { return .passThrough }
                state.pressed = false
                return .consumeAndToggle
            }
        case .doubleTap:
            switch edge {
            case .press:
                guard !state.pressed else { return .consume }
                state.pressed = true
                // Press-to-press like a mouse double-click: the second press
                // inside the window fires immediately — the gesture is
                // decided, so toggling doesn't wait for finger-off, and a
                // held second press can't slip out of the window mid-tap.
                if let first = state.pendingPressAt, now - first <= doubleTapInterval {
                    state.pendingPressAt = nil
                    return .consumeAndToggle
                }
                state.pendingPressAt = now
                return .consume
            case .release:
                guard state.pressed else { return .passThrough }
                state.pressed = false
                return .consume
            }
        }
    }
}
