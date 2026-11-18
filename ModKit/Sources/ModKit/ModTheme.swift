import AppKit
import Foundation

/// The colors a mod reads by name (`theme().muted`, `theme().border`…),
/// from a theme file's few: background, foreground, selection, sixteen
/// ANSI colors, and whatever the file names itself under `colors`.
public nonisolated enum ModTheme {
    private static func parts(_ hex: String) -> (Double, Double, Double)? {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count >= 6, let value = UInt32(text.prefix(6), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff), Double((value >> 8) & 0xff), Double(value & 0xff))
    }

    /// `amount` of `b` into `a`.
    public static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        guard let x = parts(a), let y = parts(b) else { return a }
        func channel(_ p: Double, _ q: Double) -> Int { Int((p + (q - p) * amount).rounded()) }
        return String(format: "#%02x%02x%02x", channel(x.0, y.0), channel(x.1, y.1), channel(x.2, y.2))
    }

    public static func isLight(_ background: String) -> Bool {
        guard let c = parts(background) else { return false }
        return (0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2) / 255 > 0.55
    }

    /// Every named color. `file`: a theme as its JSON holds it.
    public static func colors(from file: [String: Any]) -> [String: String] {
        let background = file["background"] as? String ?? "#1e1e1e"
        let foreground = file["foreground"] as? String ?? "#d4d4d4"
        let light = isLight(background)
        var ansi = file["ansi"] as? [String] ?? []
        let fallback = ["#000000", "#cc3333", "#33aa55", "#ccaa33", "#3377dd", "#aa55cc", "#33aaaa", "#cccccc",
                        "#666666", "#ee5555", "#55cc77", "#eecc55", "#5599ff", "#cc77ee", "#55cccc", "#ffffff"]
        while ansi.count < 16 { ansi.append(fallback[ansi.count]) }
        var out: [String: String] = [
            "background": background,
            "foreground": foreground,
            "surface": background,
            "canvas": mix(background, light ? "#000000" : "#000000", light ? 0.04 : 0.18),
            "chrome": mix(background, foreground, 0.03),
            "popover": mix(background, foreground, light ? 0.02 : 0.06),
            "raised": mix(background, foreground, 0.08),
            "hover": mix(background, foreground, 0.07),
            "selected": mix(background, foreground, 0.13),
            "border": mix(background, foreground, 0.15),
            "input": mix(background, foreground, 0.05),
            "muted": mix(foreground, background, 0.32),
            "dim": mix(foreground, background, 0.55),
            "accent": ansi[4],
            "accent_foreground": background,
            "solid": foreground,
            "solid_foreground": background,
            "selection": file["selection"] as? String ?? mix(background, ansi[4], 0.3),
            "cursor": file["cursor"] as? String ?? foreground,
            "working": ansi[3],
            "blocked": ansi[1],
            "done": ansi[2],
            "idle": mix(foreground, background, 0.55),
            "unknown": mix(foreground, background, 0.7),
        ]
        for (index, color) in ansi.prefix(16).enumerated() { out["ansi\(index)"] = color }
        for (name, color) in file["colors"] as? [String: String] ?? [:] { out[name] = color }
        return out
    }
}
