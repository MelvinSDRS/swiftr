import Foundation

/// The key held to dictate: a modifier alone (right Option, Fn…), or a key
/// with the modifiers held with it (F5, ⌃Space). Settings keeps it as JSON.
public struct DictationKey: Codable, Equatable, Sendable {
    /// The key's virtual key code.
    public var code: UInt16
    /// For a key that isn't a modifier: the modifiers held with it, as
    /// `NSEvent.ModifierFlags` raw values (⇧ ⌃ ⌥ ⌘ only).
    public var modifiers: UInt
    /// What the key is called on the keyboard it was recorded on: "F5",
    /// "Space", "A". Empty for a modifier, whose name Swiftr knows.
    public var label: String

    public init(code: UInt16, modifiers: UInt = 0, label: String = "") {
        self.code = code
        self.modifiers = modifiers & Self.modifierMask
        self.label = label
    }

    /// Right Option: what Lavoi and others use, and what the left Option
    /// that types `[` or `{` on a French keyboard leaves alone.
    public static let rightOption = DictationKey(code: 61)

    // NSEvent.ModifierFlags, as raw values.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
    public static let function: UInt = 1 << 23
    public static let modifierMask = shift | control | option | command

    /// A modifier key: its name, its sign, the flag it sets, and the bit
    /// that tells its side (IOKit's NX_DEVICE…KEYMASK).
    struct Modifier {
        let name: String
        let flag: UInt
        let side: UInt
    }

    static let modifierKeys: [UInt16: Modifier] = [
        54: Modifier(name: "Right Command", flag: command, side: 0x10),
        55: Modifier(name: "Left Command", flag: command, side: 0x08),
        56: Modifier(name: "Left Shift", flag: shift, side: 0x02),
        60: Modifier(name: "Right Shift", flag: shift, side: 0x04),
        58: Modifier(name: "Left Option", flag: option, side: 0x20),
        61: Modifier(name: "Right Option", flag: option, side: 0x40),
        59: Modifier(name: "Left Control", flag: control, side: 0x01),
        62: Modifier(name: "Right Control", flag: control, side: 0x2000),
        63: Modifier(name: "Fn", flag: function, side: 0),
    ]

    /// Every side bit: another modifier held shows in them.
    static let sideMask: UInt = modifierKeys.values.reduce(0) { $0 | $1.side }

    public var isModifier: Bool { Self.modifierKeys[code] != nil }

    /// "Right Option", "Fn", "⌃⌥Space", "F5".
    public var name: String {
        if let modifier = Self.modifierKeys[code] { return modifier.name }
        var signs = ""
        if modifiers & Self.control != 0 { signs += "⌃" }
        if modifiers & Self.option != 0 { signs += "⌥" }
        if modifiers & Self.shift != 0 { signs += "⇧" }
        if modifiers & Self.command != 0 { signs += "⌘" }
        return signs + (label.isEmpty ? "Key \(code)" : label)
    }

    /// Whether this modifier is down in `flags`, a flagsChanged event's raw
    /// modifier flags.
    public func isDown(in flags: UInt) -> Bool {
        guard let modifier = Self.modifierKeys[code] else { return false }
        return modifier.side == 0 ? flags & modifier.flag != 0 : flags & modifier.side != 0
    }

    /// Whether `flags` hold a modifier other than this one.
    func othersHeld(in flags: UInt) -> Bool {
        let own = Self.modifierKeys[code]
        let others = (Self.modifierMask | Self.function) & ~(own?.flag ?? 0)
        let otherSides = Self.sideMask & ~(own?.side ?? 0)
        return flags & others != 0 || flags & otherSides != 0
    }
}

/// Hold to dictate, release to stop: the key's presses and releases, and
/// what else the keyboard and mouse do meanwhile, turned into when to
/// start listening, when to write, and when to drop it. A modifier held
/// for a shortcut (⌥[ on a French keyboard, ⌥-click) or tapped drops what
/// was heard: nothing is written.
public struct DictationHold: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Start listening: the key went down.
        case start
        /// Stop and write what was heard: the key came up.
        case finish
        /// Stop and drop it: a shortcut or a tap, not a dictation.
        case cancel
    }

    public var key: DictationKey
    public private(set) var held = false
    private var since = 0.0

    /// Held less than this, the key was tapped: nothing to write.
    public static let shortest = 0.3

    public init(key: DictationKey) {
        self.key = key
    }

    /// A modifier went down or up. `flags` are the event's raw modifier
    /// flags, side bits included.
    public mutating func flagsChanged(code: UInt16, flags: UInt, at time: Double) -> Action {
        guard key.isModifier else { return .none }
        if code == key.code {
            if key.isDown(in: flags) {
                guard !held, !key.othersHeld(in: flags) else { return .none }
                held = true
                since = time
                return .start
            }
            return release(at: time)
        }
        // Another modifier with it: a shortcut on its way.
        return drop()
    }

    /// A key went down. Returns what to do, and whether Swiftr keeps the
    /// key from the rest of the app: the dictation key itself is kept,
    /// others go through.
    public mutating func keyDown(code: UInt16, flags: UInt, isRepeat: Bool, at time: Double) -> (Action, swallow: Bool) {
        if !key.isModifier, code == key.code, flags & DictationKey.modifierMask == key.modifiers {
            if held || isRepeat { return (.none, true) }
            held = true
            since = time
            return (.start, true)
        }
        return (drop(), false)
    }

    public mutating func keyUp(code: UInt16, at time: Double) -> (Action, swallow: Bool) {
        guard !key.isModifier, code == key.code else { return (.none, false) }
        let wasHeld = held
        return (release(at: time), wasHeld)
    }

    /// A click, or Swiftr going to the back while the key is down: its
    /// release won't come, or the key served something else.
    public mutating func interrupted() -> Action {
        drop()
    }

    private mutating func release(at time: Double) -> Action {
        guard held else { return .none }
        held = false
        return time - since < Self.shortest ? .cancel : .finish
    }

    private mutating func drop() -> Action {
        guard held else { return .none }
        held = false
        return .cancel
    }
}
