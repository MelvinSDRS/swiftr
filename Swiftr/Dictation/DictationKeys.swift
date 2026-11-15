import AppKit
import HerdrKit

/// Watches Swiftr's keyboard for the dictation key (Settings › Dictation):
/// held, Swiftr listens; let go, it writes. Only while Swiftr is in front:
/// the text goes in Swiftr, and watching other apps' keys would need the
/// Accessibility permission.
@MainActor
final class DictationKeys {
    static let shared = DictationKeys()

    private var hold: DictationHold?
    private var monitor: Any?
    /// The key's dictation is under way, not the button's.
    private var holding = false

    func install() {
        keyChanged()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(self?.hold?.interrupted() ?? .none) }
        }
    }

    /// Settings chose another key, or none.
    func keyChanged() {
        if holding { apply(hold?.interrupted() ?? .none) }
        hold = Dictation.key.map { DictationHold(key: $0) }
    }

    /// Settings records a new key: the old one does nothing meanwhile.
    var paused = false

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Esc drops a dictation, whichever way it started.
        if event.type == .keyDown, event.keyCode == 53, Dictation.shared.phase == .listening {
            holding = false
            if var hold { _ = hold.interrupted(); self.hold = hold }
            Dictation.shared.cancel()
            return nil
        }
        guard !paused, var hold else { return event }
        let time = event.timestamp
        var swallow = false
        let action: DictationHold.Action
        switch event.type {
        case .flagsChanged:
            action = hold.flagsChanged(code: event.keyCode, flags: UInt(event.modifierFlags.rawValue), at: time)
        case .keyDown:
            (action, swallow) = hold.keyDown(code: event.keyCode, flags: UInt(event.modifierFlags.rawValue), isRepeat: event.isARepeat, at: time)
        case .keyUp:
            (action, swallow) = hold.keyUp(code: event.keyCode, at: time)
        default:
            action = hold.interrupted()
        }
        self.hold = hold
        apply(action)
        return swallow ? nil : event
    }

    private func apply(_ action: DictationHold.Action) {
        let dictation = Dictation.shared
        switch action {
        case .none:
            break
        case .start:
            // The button's dictation goes on: the key doesn't start another.
            // Until the speech model is downloaded, the key is only a key.
            guard dictation.phase != .listening, dictation.isReady else { return }
            holding = dictation.start(byKey: true)
        case .finish:
            guard holding else {
                dictation.sayWhyNot()
                return
            }
            holding = false
            dictation.finish()
        case .cancel:
            dictation.forgetWhyNot()
            guard holding else { return }
            holding = false
            dictation.cancel()
        }
    }
}
