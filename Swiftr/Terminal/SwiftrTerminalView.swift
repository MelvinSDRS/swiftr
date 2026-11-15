import AppKit
import Carbon.HIToolbox
import HerdrKit
@preconcurrency import SwiftTerm
import Synchronization

/// Where the engine's own replies go. Set on the main thread, read on the
/// thread that parses (the connection's reader).
nonisolated struct ReplyRoute: Sendable {
    let connection: CoreConnection
    let channel: UInt32
    /// The core and this attach both said `automatic_input`.
    let automatic: Bool
}

/// A SwiftTerm view whose engine replies are told apart from typing at their
/// source (herdr-core schema/README.md: "Tag replies at their source").
///
/// Typing and pastes reach `TerminalViewDelegate.send(source: TerminalView)`.
/// What the engine sends by itself (answers to queries while parsing, size
/// reports when the grid changes) comes through `send(source: Terminal)`,
/// overridden here. Mouse reports also go that way, but a person caused
/// them: those are sent as typing.
final class SwiftrTerminalView: TerminalView {
    nonisolated let route = Mutex<ReplyRoute?>(nil)

    /// Called when this view gains or loses keyboard focus.
    var onFocusChange: ((Bool) -> Void)?

    /// > 0 while AppKit resizes the view: the reports that causes are not typing.
    private var resizing = 0

    override func setFrameSize(_ newSize: NSSize) {
        resizing += 1
        defer { resizing -= 1 }
        super.setFrameSize(newSize)
    }

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            onFocusChange?(newValue)
        }
    }

    /// Sends one of the `lineKeys` to the program, or says the key isn't one.
    /// The app's key monitor calls this: SwiftTerm's `keyDown` is public, not
    /// open, so it can't be overridden here.
    func takeLineKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), let bytes = lineKeys(for: event) else { return false }
        selectNone()
        send(bytes)
        return true
    }

    /// The macOS keys that move and delete in a line of text, sent as the
    /// readline keys shells and agents know, as Ghostty and iTerm2 send them:
    /// ⌘← ⌘→ go to the line's start and end (⌃A, ⌃E), ⌘⌫ deletes the line
    /// (⌃U), ⌘⌦ deletes to its end (⌃K), ⌥⌦ the next word (Esc d). SwiftTerm
    /// sends nothing for the ⌘ ones. It sends ⌥← ⌥→ ⌥⌫ as Esc b, Esc f and
    /// Esc ⌫ while Option is Meta on those keys; when Option types characters
    /// everywhere, they are sent here.
    private func lineKeys(for event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let code = Int(event.keyCode)
        if flags == .command {
            switch code {
            case kVK_LeftArrow: return [0x01]
            case kVK_RightArrow: return [0x05]
            case kVK_Delete: return [0x15]
            case kVK_ForwardDelete: return [0x0b]
            default: return nil
            }
        }
        if flags == .option {
            if code == kVK_ForwardDelete { return [0x1b, 0x64] }
            guard !optionAsMetaKey, !optionAsMetaKeyForFunctionalKeys else { return nil }
            switch code {
            case kVK_LeftArrow: return EscapeSequences.emacsBack
            case kVK_RightArrow: return EscapeSequences.emacsForward
            case kVK_Delete: return [0x1b, 0x7f]
            default: return nil
            }
        }
        return nil
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Focus reports: the core sends them itself, from FOCUS frames.
        if data.count == 3, data.first == 0x1b, data[data.startIndex + 1] == 0x5b, data.last == 0x49 || data.last == 0x4f {
            return
        }
        guard let route = route.withLock({ $0 }) else { return }
        let human = Thread.isMainThread && MainActor.assumeIsolated { self.handlingInput }
        let bytes = Array(data)
        if route.automatic && !human {
            route.connection.send(channel: route.channel, kind: .automaticInput, payload: bytes)
        } else {
            route.connection.input(route.channel, bytes)
        }
    }

    /// Whether AppKit is delivering a person's mouse or key event right now.
    private var handlingInput: Bool {
        guard resizing == 0, let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .scrollWheel, .keyDown, .keyUp:
            return true
        default:
            return false
        }
    }
}

/// Draws Nerd Font icons the terminal font lacks with Symbols Nerd Font Mono,
/// when it is installed.
nonisolated final class NerdFontFallback: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared = NerdFontFallback()

    private let name = "Symbols Nerd Font Mono"
    private let available: Bool
    private let fonts = Mutex<[CGFloat: CTFont]>([:])

    let generation: UInt64 = 1

    private init() {
        let probe = CTFontCreateWithName(name as CFString, 12, nil)
        available = (CTFontCopyFamilyName(probe) as String) == "Symbols Nerd Font Mono"
    }

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        guard available else { return nil }
        let v = scalar.value
        // Powerline separators fill their cell; the rest are icons.
        if (0xE0B0 ... 0xE0D7).contains(v) { return TerminalGlyphPlacementPolicy(placement: .stretch) }
        let nerd = (0xE000 ... 0xF8FF).contains(v) || (0xF0000 ... 0xFFFFD).contains(v) || (0x23FB ... 0x23FE).contains(v) || v == 0x2B58
        guard nerd, covers(scalar) else { return nil }
        return TerminalGlyphPlacementPolicy(placement: .icon)
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        guard available else { return nil }
        return fonts.withLock { cache in
            if let f = cache[size] { return f }
            let f = CTFontCreateWithName(name as CFString, size, nil)
            cache[size] = f
            return f
        }
    }

    private func covers(_ scalar: Unicode.Scalar) -> Bool {
        guard let font = fallbackFont(forPointSize: 12) else { return false }
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
    }
}
