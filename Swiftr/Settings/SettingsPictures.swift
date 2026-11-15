import AppKit
import HerdrKit
import SwiftUI

// MARK: Choices shown as pictures

/// A few choices, each shown by a picture: a click on the picture picks it,
/// as System Settings' Appearance pane does.
struct ChoiceTiles<Value: Hashable, Picture: View>: View {
    struct Choice: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }

        init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    @Binding var selection: Value
    let choices: [Choice]
    var size = CGSize(width: 148, height: 92)
    /// Round corners and an edge around each picture; an app icon has its own.
    var framed = true
    @ViewBuilder let picture: (Value) -> Picture

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(choices) { choice in
                let chosen = choice.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = choice.value }
                } label: {
                    VStack(spacing: 7) {
                        picture(choice.value)
                            .frame(width: size.width, height: size.height)
                            .tileFrame(chosen: chosen, framed: framed, corner: framed ? 7 : 16)
                        Text(choice.title)
                            .font(.callout)
                            .foregroundStyle(chosen ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

extension View {
    /// A choice's picture: round corners, a thin edge, and a ring in the
    /// accent color around the chosen one.
    func tileFrame(chosen: Bool, framed: Bool = true, corner: CGFloat = 7) -> some View {
        modifier(TileFrame(chosen: chosen, framed: framed, corner: corner))
    }
}

private struct TileFrame: ViewModifier {
    let chosen: Bool
    let framed: Bool
    let corner: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if framed {
                content
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5) }
            } else {
                content
            }
        }
        .padding(4)
        .overlay {
            RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(chosen ? 1 : 0)
        }
    }
}

/// The right part of a box, cut on a slant: a dark picture over its light
/// twin shows both, as System Settings' Automatic does.
nonisolated struct SlantHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

extension TerminalTheme {
    var pictureBackground: Color { Color(nsColor: backgroundColor) }
    var pictureText: Color { Color(nsColor: foregroundColor) }

    /// One of the sixteen colors.
    func pictureColor(_ i: Int) -> Color {
        guard ansi.indices.contains(i), let color = NSColor(hex: ansi[i]) else { return pictureText }
        return Color(nsColor: color)
    }
}

// MARK: Appearance

/// A window in light, in dark, or both cut on a slant for Automatic, its
/// terminals in the colors each would have.
struct AppearancePicture: View {
    @Environment(AppModel.self) private var model
    let look: Appearance

    var body: some View {
        switch look {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .automatic:
            window(dark: false)
                .overlay { window(dark: true).mask { SlantHalf() } }
        }
    }

    private func window(dark: Bool) -> MiniWindow {
        let prefs = model.prefs
        // Swiftr's theme turns with the window; another keeps its colors.
        let theme = prefs.themeName == Preferences.swiftrThemeName ? TerminalTheme.swiftr(dark: dark) : prefs.theme
        return MiniWindow(dark: dark, theme: theme, tabBar: prefs.showsTabBar,
                          sidebar: prefs.agentsPlace == .top ? .agentsAbove : .agentsBelow)
    }
}

/// The app icon in one of its looks; Automatic shows both.
struct AppIconPicture: View {
    let style: AppIconStyle

    var body: some View {
        switch style {
        case .light: icon("AppIconLight")
        case .dark: icon("AppIconDark")
        case .automatic:
            icon("AppIconLight")
                .overlay { icon("AppIconDark").mask { SlantHalf() } }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

/// Every theme, each drawn in its own colors: a click picks it.
struct ThemeGallery: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let prefs = model.prefs
        let names = [Preferences.swiftrThemeName] + prefs.themeNames
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 16)], alignment: .leading, spacing: 14) {
            ForEach(names, id: \.self) { name in
                let chosen = name == prefs.themeName
                Button {
                    withAnimation(.snappy(duration: 0.25)) { prefs.themeName = name }
                } label: {
                    VStack(spacing: 6) {
                        ThemePicture(name: name)
                            .frame(height: 84)
                            .tileFrame(chosen: chosen)
                        VStack(spacing: 1) {
                            Text(Self.title(name))
                                .font(.callout)
                                .foregroundStyle(chosen ? .primary : .secondary)
                            Text(kind(name))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.title(name))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    /// "catppuccin-mocha" as "Catppuccin Mocha".
    static func title(_ name: String) -> String {
        if name == Preferences.swiftrThemeName { return "Swiftr" }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func kind(_ name: String) -> String {
        if name == Preferences.swiftrThemeName { return "Light and dark" }
        return model.prefs.themes[name]?.isDark == false ? "Light" : "Dark"
    }
}

/// A theme's card: Swiftr's in light and dark at once.
private struct ThemePicture: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let family = model.prefs.fontName
        if name == Preferences.swiftrThemeName {
            ThemeSwatch(theme: .paper, family: family)
                .overlay { ThemeSwatch(theme: .graphite, family: family).mask { SlantHalf() } }
        } else if let theme = model.prefs.themes[name] {
            ThemeSwatch(theme: theme, family: family)
        }
    }
}

/// A theme in small: a few lines of a shell in its colors, and its sixteen
/// colors under them.
struct ThemeSwatch: View {
    let theme: TerminalTheme
    let family: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(ShellSample.short(theme).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            Spacer(minLength: 0)
            PaletteStrip(theme: theme)
        }
        .font(Font(Preferences.font(family: family, size: 8.5) as CTFont))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.pictureBackground)
        .accessibilityHidden(true)
    }
}

/// A theme's sixteen colors, side by side.
struct PaletteStrip: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0 ..< 16, id: \.self) { i in
                Rectangle().fill(theme.pictureColor(i))
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}

/// A shell's lines, colored as a terminal draws them with a theme.
enum ShellSample {
    static func run(_ text: String, _ color: Color, bold: Bool = false, selected: Color? = nil) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = color
        if bold { a.inlinePresentationIntent = .stronglyEmphasized }
        if let selected { a.backgroundColor = selected }
        return a
    }

    static func prompt(_ t: TerminalTheme, folder: String) -> AttributedString {
        run(folder, t.pictureColor(4)) + run(" main", t.pictureColor(5)) + run(" ❯ ", t.pictureColor(2))
    }

    /// The Terminal pane's sample, with a word selected and the cursor shown
    /// or not, as it blinks.
    static func lines(_ t: TerminalTheme, cursor: Bool) -> [AttributedString] {
        let fg = t.pictureText
        let folder = t.pictureColor(4)
        let selection = Color(nsColor: t.selectionColor)
        let here = "~/Projects/swiftr"
        return [
            prompt(t, folder: here) + run("ls", fg),
            run("HerdrKit", folder, bold: true) + run("  ", fg) + run("project.yml", fg, selected: selection)
                + run("  ", fg) + run("scripts", folder, bold: true) + run("  ", fg) + run("Swiftr", folder, bold: true),
            prompt(t, folder: here) + run("git diff --stat", fg),
            run(" Swiftr/Settings/SettingsView.swift | 9 ", fg) + run("+++++", t.pictureColor(2)) + run("----", t.pictureColor(1)),
            prompt(t, folder: here) + run("█", cursor ? Color(nsColor: t.cursorColor) : .clear),
        ]
    }

    /// A theme card's few lines.
    static func short(_ t: TerminalTheme) -> [AttributedString] {
        let fg = t.pictureText
        let folder = t.pictureColor(4)
        return [
            prompt(t, folder: "~/swiftr") + run("ls", fg),
            run("HerdrKit", folder, bold: true) + run("  build  ", fg) + run("Swiftr", folder, bold: true),
            prompt(t, folder: "~/swiftr") + run("git diff", fg),
            run(" app.swift | 9 ", fg) + run("+++++", t.pictureColor(2)) + run("----", t.pictureColor(1)),
        ]
    }
}

// MARK: The window in small

/// Swiftr's window in small, to show what a setting changes: the sidebar,
/// the card in the terminals' colors, the top row over it.
struct MiniWindow: View {
    enum Sidebar {
        case spaces
        /// A space open on its tabs.
        case tabs
        case agentsBelow
        case agentsAbove
    }

    enum Content {
        case terminal
        /// Claude Code (or another agent) as it draws itself in a terminal.
        case claude
        /// A conversation, as Messages shows it.
        case messages
    }

    /// The part a setting changes, drawn in the accent color.
    enum Mark {
        case tabBar
        case sidebarTabs
        case agents
    }

    var dark: Bool
    var theme: TerminalTheme
    var tabBar = true
    var sidebar = Sidebar.agentsBelow
    var content = Content.terminal
    var mark: Mark? = nil
    /// The color of the agent's mark in `.claude`: Claude's orange.
    var agentColor = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        Canvas { g, size in
            draw(&g, size)
        }
        .accessibilityHidden(true)
    }

    /// Drawn on a 128 × 80 grid, stretched to the size given.
    private func draw(_ g: inout GraphicsContext, _ size: CGSize) {
        let sx = size.width / 128
        let sy = size.height / 80
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
        }
        func fill(_ r: CGRect, _ radius: CGFloat, _ color: Color) {
            g.fill(Path(roundedRect: r, cornerRadius: radius * min(sx, sy), style: .continuous), with: .color(color))
        }
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ color: Color, height: CGFloat = 2) {
            fill(box(x, y - height / 2, w, height), height / 2, color)
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ color: Color) {
            g.fill(Path(ellipseIn: box(x - d / 2, y - d / 2, d, d)), with: .color(color))
        }
        let ink: Color = dark ? .white : .black
        let accent = Color.accentColor
        let fg = theme.pictureText

        // The window: the sidebar's material all over, under the card.
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(white: 0.17) : Color(white: 0.9)))
        let lights = [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)]
        for (i, color) in lights.enumerated() {
            dot(6.5 + CGFloat(i) * 5, 6, 3.3, color)
        }

        // The sidebar.
        func header(_ y: CGFloat, marked: Bool = false) {
            bar(5.5, y, 12, marked ? accent : ink.opacity(0.28), height: 1.6)
        }
        func spaceRow(_ y: CGFloat, _ icon: Color, _ width: CGFloat, selected: Bool = false) {
            if selected { fill(box(2.5, y - 2.9, 33, 5.8), 1.8, ink.opacity(0.1)) }
            fill(box(5.5, y - 1.6, 3.2, 3.2), 0.9, icon)
            bar(11, y, width, ink.opacity(0.45))
        }
        func agentRow(_ y: CGFloat, _ state: Color, _ width: CGFloat) {
            dot(7.1, y, 2.6, state)
            bar(11, y, width, ink.opacity(0.45))
        }
        let icons: [Color] = [.blue, .orange, .green, .purple]
        func spaces(from y: CGFloat, rows: Int) {
            header(y)
            for i in 0 ..< rows {
                spaceRow(y + 5.5 + CGFloat(i) * 6, icons[i % icons.count], [18, 14, 20, 12][i % 4], selected: i == 0)
            }
        }
        func agents(from y: CGFloat) {
            let marked = mark == .agents
            if marked { fill(box(2, y - 3, 34, 24.5), 2.5, accent.opacity(0.16)) }
            header(y, marked: marked)
            agentRow(y + 5.5, .orange, 17)
            agentRow(y + 11.5, accent, 13)
            agentRow(y + 17.5, ink.opacity(0.3), 19)
        }
        func line(_ y: CGFloat) {
            fill(box(4, y, 30, 0.5), 0, ink.opacity(0.15))
        }
        switch sidebar {
        case .spaces:
            spaces(from: 15, rows: 4)
        case .tabs:
            let marked = mark == .sidebarTabs
            header(15)
            // An open space, its tabs under it, then a closed one.
            var open = Path()
            open.move(to: CGPoint(x: 2.4 * sx, y: 19.6 * sy))
            open.addLine(to: CGPoint(x: 4.6 * sx, y: 19.6 * sy))
            open.addLine(to: CGPoint(x: 3.5 * sx, y: 21.4 * sy))
            open.closeSubpath()
            g.fill(open, with: .color(ink.opacity(0.4)))
            spaceRow(20.5, icons[0], 16)
            for i in 0 ..< 3 {
                let y = 26.5 + CGFloat(i) * 5.5
                if i == 0 { fill(box(7, y - 2.6, 28.5, 5.2), 1.7, marked ? accent.opacity(0.3) : ink.opacity(0.1)) }
                fill(box(9, y - 1.3, 2.6, 2.6), 0.7, marked ? accent : ink.opacity(0.35))
                bar(13.5, y, [15, 11, 17][i], marked ? accent.opacity(0.85) : ink.opacity(0.45))
            }
            var closed = Path()
            closed.move(to: CGPoint(x: 2.6 * sx, y: 42.6 * sy))
            closed.addLine(to: CGPoint(x: 2.6 * sx, y: 45 * sy))
            closed.addLine(to: CGPoint(x: 4.4 * sx, y: 43.8 * sy))
            closed.closeSubpath()
            g.fill(closed, with: .color(ink.opacity(0.4)))
            spaceRow(43.8, icons[1], 13)
        case .agentsBelow:
            spaces(from: 15, rows: 3)
            line(37.5)
            agents(from: 43)
        case .agentsAbove:
            agents(from: 15)
            line(37.5)
            spaces(from: 43, rows: 3)
        }

        // The card, with the top row over it.
        let card = box(40, 3, 85, 74)
        let cardShape = Path(roundedRect: card, cornerRadius: 5 * min(sx, sy), style: .continuous)
        g.fill(cardShape, with: .color(theme.pictureBackground))
        g.stroke(cardShape, with: .color(dark ? .white.opacity(0.1) : .black.opacity(0.12)), lineWidth: 0.5)
        if tabBar {
            let marked = mark == .tabBar
            fill(box(43, 4.5, 19, 7), 3.5, marked ? accent : fg.opacity(0.16))
            bar(46.5, 8, 12, marked ? .white : fg.opacity(0.75), height: 1.8)
            bar(66, 8, 11, marked ? accent.opacity(0.85) : fg.opacity(0.4), height: 1.8)
            bar(81, 8, 9, marked ? accent.opacity(0.85) : fg.opacity(0.4), height: 1.8)
        }
        // The buttons at the row's end: the splits, the favorites and the +.
        fill(box(100, 4.5, 22, 7), 3.5, fg.opacity(0.1))
        for i in 0 ..< 3 {
            dot(104.5 + CGFloat(i) * 6.5, 8, 2.2, fg.opacity(0.45))
        }

        let top: CGFloat = 16
        switch content {
        case .terminal:
            bar(45, top + 1, 4, theme.pictureColor(2))
            bar(51, top + 1, 22, fg.opacity(0.85))
            bar(45, top + 7, 30, fg.opacity(0.55))
            bar(77, top + 7, 12, theme.pictureColor(4))
            bar(45, top + 13, 22, fg.opacity(0.55))
            bar(69, top + 13, 16, theme.pictureColor(3))
            bar(45, top + 19, 34, fg.opacity(0.55))
            bar(45, top + 25, 4, theme.pictureColor(2))
            fill(box(51, top + 23, 2.6, 4), 0.3, Color(nsColor: theme.cursorColor))
        case .claude:
            dot(46.6, top + 1, 3.2, agentColor)
            bar(51, top + 1, 26, fg.opacity(0.85))
            bar(51, top + 7, 50, fg.opacity(0.55))
            bar(51, top + 13, 42, fg.opacity(0.55))
            bar(51, top + 19, 30, fg.opacity(0.55))
            let field = Path(roundedRect: box(44, 52, 77.5, 11), cornerRadius: 2 * min(sx, sy), style: .continuous)
            g.stroke(field, with: .color(fg.opacity(0.4)), lineWidth: 0.8)
            bar(47.5, 57.5, 2.4, fg.opacity(0.75))
            bar(52, 57.5, 22, fg.opacity(0.3))
            bar(45, 68, 38, fg.opacity(0.3), height: 1.6)
        case .messages:
            fill(box(86, top, 34, 9), 3.5, fg.opacity(0.14))
            bar(90, top + 4.5, 24, fg.opacity(0.75))
            bar(45, top + 16, 60, fg.opacity(0.6))
            bar(45, top + 22, 52, fg.opacity(0.6))
            bar(45, top + 28, 36, fg.opacity(0.6))
            let field = box(44, 58, 77.5, 15)
            fill(field, 6, fg.opacity(0.07))
            g.stroke(Path(roundedRect: field, cornerRadius: 6 * min(sx, sy), style: .continuous), with: .color(fg.opacity(0.16)), lineWidth: 0.6)
            bar(48.5, 63.5, 22, fg.opacity(0.3))
            dot(116, 67.5, 6, theme.accentColor.map { Color(nsColor: $0) } ?? accent)
        }
    }
}

// MARK: Terminal

/// A shell as a terminal draws it in these colors, this font and size: a
/// word selected, and the cursor, blinking or not.
struct TerminalSample: View {
    let theme: TerminalTheme
    let family: String
    let size: Double
    var blinks = false

    var body: some View {
        Group {
            if blinks {
                TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
                    lines(cursor: Int(timeline.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0)
                }
            } else {
                lines(cursor: true)
            }
        }
        .font(Font(Preferences.font(family: family, size: size) as CTFont))
        .lineLimit(1)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.pictureBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func lines(cursor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ShellSample.lines(theme, cursor: cursor).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
    }
}

/// A key on a keyboard: its label on a raised cap.
struct KeyCap: View {
    let label: String
    var tint: Color? = nil
    var small = false
    var width: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 4 : 6, style: .continuous)
        Text(label)
            .font(small ? .caption.weight(.medium) : .system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            .padding(.horizontal, small ? 5 : 0)
            .frame(minWidth: small ? 0 : width, minHeight: small ? 18 : 26)
            .background {
                shape
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.background))
                    .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
            }
            .overlay {
                shape.strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.45)) } ?? AnyShapeStyle(.separator), lineWidth: 0.5)
            }
    }
}

/// What ⌥ does with each kind of key, in the mode chosen: the characters
/// the keyboard layout types, or Meta, which sends Esc and then the key.
struct OptionKeyPicture: View {
    let mode: OptionKey

    var body: some View {
        let lettersMeta = mode == .meta
        let othersMeta = mode != .characters
        HStack(alignment: .top, spacing: 12) {
            KeyCap(label: "⌥", width: 40)
            Text("+")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(height: 26)
            group(["Q", "W", "E", "R"],
                  tint: lettersMeta ? .orange : .blue,
                  title: lettersMeta ? "Meta" : "Characters",
                  detail: lettersMeta ? "⌥B and ⌥F move by words in the shell" : "é, ©, @… as your layout types them")
            group(["←", "→", "↩", "⌫"],
                  tint: othersMeta ? .orange : .gray,
                  title: othersMeta ? "Meta" : "Not Meta",
                  detail: othersMeta ? "⌥← and ⌥→ jump a word" : "⌥ changes nothing the shell reads")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .animation(.snappy, value: mode)
        .accessibilityHidden(true)
    }

    private func group(_ keys: [String], tint: Color, title: String, detail: String) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap(label: $0, tint: tint) }
            }
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 136)
        }
    }
}

// MARK: Agents

/// The tab strip's end, as the window shows it: the split buttons, then
/// the favorites and the +.
struct FavoritesPicture: View {
    let favorites: [Programs.Program]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ProgramIcon(key: "shell", size: 13)
                    .foregroundStyle(.secondary)
                Text("zsh")
                    .font(.callout)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 16)
            HStack(spacing: 0) {
                button { Image(systemName: "rectangle.split.2x1") }
                button { Image(systemName: "rectangle.split.1x2") }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .glassEffect(.regular, in: .capsule)
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    if favorites.isEmpty {
                        button { Image(systemName: "star").foregroundStyle(.tertiary) }
                    }
                    ForEach(favorites, id: \.key) { agent in
                        button {
                            ProgramIcon(key: agent.key, size: 15)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                button { Image(systemName: "plus") }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }

    private func button(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(width: 30, height: 26)
    }
}

/// What Swiftr does when an agent's state changes: a sound for each, picked
/// here.
struct AlertFlow: View {
    @Environment(AppModel.self) private var model
    @State private var sounds = Preferences.soundNames
    static let row: CGFloat = 30
    static let gap: CGFloat = 14

    var body: some View {
        @Bindable var prefs = model.prefs
        HStack(spacing: 0) {
            StateChip(title: "Working", attention: .working)
            Branches()
                .frame(width: 44, height: Self.row * 2 + Self.gap)
            VStack(alignment: .leading, spacing: Self.gap) {
                outcome("Needs you", attention: .needsYou, sound: $prefs.needsYouSound, alert: .needsYou)
                outcome("Done", attention: .done, sound: $prefs.finishedSound, alert: .finished)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func outcome(_ title: String, attention: Attention, sound: Binding<String>, alert: AgentAlert) -> some View {
        HStack(spacing: 8) {
            StateChip(title: title, attention: attention)
                .frame(width: 118, alignment: .leading)
            Image(systemName: sound.wrappedValue.isEmpty ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Picker("“\(title)” sound", selection: sound) {
                Text("None").tag("")
                ForEach(sounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: sound.wrappedValue) { model.alerts.play(alert) }
            Button {
                model.alerts.play(alert)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(sound.wrappedValue.isEmpty)
            .help("Play the sound")
        }
        .frame(height: Self.row)
    }
}

/// An agent in one state, marked as the sidebar marks it.
struct StateChip: View {
    let title: String
    let attention: Attention

    var body: some View {
        HStack(spacing: 6) {
            ProgramIcon(key: "claude", size: 14)
            Text(title)
                .font(.callout.weight(.medium))
            AttentionDot(attention: attention)
        }
        .padding(.horizontal, 10)
        .frame(height: AlertFlow.row)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
    }

    private var edge: Color {
        switch attention {
        case .needsYou: .orange.opacity(0.6)
        case .done: .accentColor.opacity(0.6)
        default: .secondary.opacity(0.25)
        }
    }
}

/// Lines from one state to the two that follow it.
private struct Branches: View {
    var body: some View {
        Canvas { g, size in
            let mid = size.height / 2
            var lines = Path()
            var heads = Path()
            for y in [AlertFlow.row / 2, size.height - AlertFlow.row / 2] {
                lines.move(to: CGPoint(x: 0, y: mid))
                lines.addCurve(to: CGPoint(x: size.width - 7, y: y),
                               control1: CGPoint(x: size.width * 0.55, y: mid),
                               control2: CGPoint(x: size.width * 0.3, y: y))
                heads.move(to: CGPoint(x: size.width - 8, y: y - 3.5))
                heads.addLine(to: CGPoint(x: size.width - 1, y: y))
                heads.addLine(to: CGPoint(x: size.width - 8, y: y + 3.5))
                heads.closeSubpath()
            }
            g.stroke(lines, with: .style(.tertiary), lineWidth: 1.5)
            g.fill(heads, with: .style(.tertiary))
        }
        .accessibilityHidden(true)
    }
}

/// A notification as macOS shows Swiftr's, faded while they're off.
struct NotificationPicture: View {
    let on: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude needs you")
                        .fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text("now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Swiftr / Settings")
                Text("Approve Bash: swift test")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 330)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .opacity(on ? 1 : 0.4)
        .saturation(on ? 1 : 0)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .animation(.snappy, value: on)
        .accessibilityHidden(true)
    }
}

// MARK: An agent

/// The Messages field and what shows under it, as the agent's settings have
/// it: its usage (the account's own numbers once read, an example until
/// then) and its status line. What a switch hides shows faint in a dashed
/// frame: what the switch brings back.
struct UnderFieldPicture: View {
    @Environment(AppModel.self) private var model
    let agent: ChatAgent
    let usage: UsageSettings
    let statusLine: Bool

    var body: some View {
        let theme = model.prefs.theme
        let now = Date()
        let report = model.usage.latest(of: agent) ?? Self.example(agent, now: now)
        let windows = usage.arrange(report.windows).map { $0.current(at: now) }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(theme.accentColor.map { Color(nsColor: $0) } ?? .accentColor)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .frame(height: 40)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if agent.hasUsage {
                        meters(windows, now: now)
                            .hiddenBySwitch(!usage.shown)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Label("main", systemImage: "arrow.triangle.branch")
                        Image(systemName: "keyboard")
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                if agent.hasStatusLine {
                    Text(sampleLine)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .hiddenBySwitch(!statusLine)
                }
            }
            .font(.system(size: 13 * 0.8))
            .padding(.horizontal, 16)
        }
        .padding(14)
        .background(theme.pictureBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .animation(.snappy, value: usage)
        .animation(.snappy, value: statusLine)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func meters(_ windows: [UsageWindow], now: Date) -> some View {
        if windows.isEmpty {
            Text("No limit chosen")
                .foregroundStyle(.tertiary)
        } else {
            // As the strip under the field fits itself to the room.
            ViewThatFits(in: .horizontal) {
                UsageMeters(windows: windows, settings: usage, size: 13, now: now, form: .full)
                UsageMeters(windows: windows, settings: usage, size: 13, now: now, form: .bars)
                UsageMeters(windows: windows, settings: usage, size: 13, now: now, form: .numbers)
            }
        }
    }

    private var placeholder: String {
        agent == .gemini ? "Write to Gemini · / for commands · @ for files" : "Write to \(agent.name) · / for commands · ! for shell"
    }

    private var sampleLine: String {
        switch agent {
        case .claude: "~/Projects/swiftr · 32% of context used"
        case .codex: "weekly limit 59% left"
        case .gemini: "macOS Seatbelt (permissive-open)"
        case .opencode: ""
        }
    }

    /// Numbers to show what each limit looks like, before real ones.
    static func example(_ agent: ChatAgent, now: Date) -> UsageReport {
        let hour: TimeInterval = 3600
        let windows: [UsageWindow] = switch agent {
        case .claude: [
            UsageWindow(id: "session", title: "Session", used: 38, resetsAt: now + 2 * hour + 300, length: 5 * hour),
            UsageWindow(id: "weekly", title: "Weekly", used: 71, resetsAt: now + 50 * hour, length: 168 * hour),
            UsageWindow(id: "model:fable", title: "Fable", used: 24, resetsAt: now + 50 * hour, length: 168 * hour),
        ]
        case .codex: [
            UsageWindow(id: "session", title: "Session", used: 23, resetsAt: now + 3 * hour, length: 5 * hour),
            UsageWindow(id: "weekly", title: "Weekly", used: 41, resetsAt: now + 98 * hour, length: 168 * hour),
        ]
        case .gemini: [UsageWindow(id: "daily", title: "Daily", used: 12, length: 24 * hour)]
        case .opencode: []
        }
        return UsageReport(windows: windows, at: now)
    }
}

private extension View {
    /// Turned off by its switch: faint, in a dashed frame.
    func hiddenBySwitch(_ hidden: Bool) -> some View {
        opacity(hidden ? 0.3 : 1)
            .padding(.horizontal, hidden ? 6 : 0)
            .padding(.vertical, hidden ? 2 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .opacity(hidden ? 1 : 0)
            }
            .padding(.leading, hidden ? -6 : 0)
    }
}

// MARK: herdr-core

/// Swiftr, the herdr-core it talks to, and the machines that core reaches.
struct ConnectionPicture: View {
    @Environment(AppModel.self) private var model
    static let row: CGFloat = 34
    static let gap: CGFloat = 8

    var body: some View {
        let machines = model.machineItems
        let count = CGFloat(max(machines.count, 1))
        let height = count * Self.row + (count - 1) * Self.gap
        HStack(alignment: .iconMiddle, spacing: 0) {
            node(title: "Swiftr", detail: "This app") {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 42, height: 42)
            }
            Wire(link: model.link)
                .frame(width: 60, height: 30)
            node(title: "herdr-core", detail: coreDetail) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.gradient)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(2)
            }
            Fan(colors: machines.map { Self.color(of: $0.state) })
                .frame(width: 40, height: height)
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(machines) { machine in
                    MachineChip(machine: machine, detail: detail(of: machine), color: Self.color(of: machine.state))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var coreDetail: String {
        let version = model.connection?.version ?? ""
        return version.isEmpty ? model.endpoint.session : "\(model.endpoint.session) · \(version)"
    }

    private func node(title: String, detail: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 4) {
            icon()
                .alignmentGuide(.iconMiddle) { $0[VerticalAlignment.center] }
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 92)
    }

    private func detail(of machine: MachineItem) -> String {
        switch machine.state {
        case "connected":
            if machine.name.isEmpty { return "This Mac" }
            let target = model.remotes.first { $0.name == machine.name }?.target ?? machine.name
            return "ssh \(target)"
        case "connecting": return "Connecting…"
        case "needs_login": return "Needs a login"
        default: return machine.why ?? "Unreachable"
        }
    }

    static func color(of state: String) -> Color {
        switch state {
        case "connected": .green
        case "connecting": .orange
        case "needs_login": .yellow
        default: .red
        }
    }
}

extension VerticalAlignment {
    /// The middle of a node's icon, which the lines between nodes meet.
    nonisolated private enum IconMiddle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    static let iconMiddle = VerticalAlignment(IconMiddle.self)
}

/// The socket between Swiftr and herdr-core: whole once connected, dashed
/// while connecting, cut when it failed.
private struct Wire: View {
    let link: AppModel.Link

    var body: some View {
        let color: Color = switch link {
        case .connected: .green
        case .connecting, .installing: .orange
        case .failed, .installFailed: .red
        }
        ZStack {
            Canvas { g, size in
                var p = Path()
                p.move(to: CGPoint(x: 4, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width - 4, y: size.height / 2))
                g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: link == .connected ? [] : [4, 4]))
            }
            Text("socket")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: -11)
            switch link {
            case .failed, .installFailed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
            default:
                EmptyView()
            }
        }
    }
}

/// Lines from herdr-core to each machine, in the color of its state.
private struct Fan: View {
    let colors: [Color]

    var body: some View {
        Canvas { g, size in
            let mid = size.height / 2
            for (i, color) in colors.enumerated() {
                let y = ConnectionPicture.row / 2 + CGFloat(i) * (ConnectionPicture.row + ConnectionPicture.gap)
                var p = Path()
                p.move(to: CGPoint(x: 2, y: mid))
                p.addCurve(to: CGPoint(x: size.width, y: y),
                           control1: CGPoint(x: size.width * 0.55, y: mid),
                           control2: CGPoint(x: size.width * 0.45, y: y))
                g.stroke(p, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A machine the core reaches: its icon, name, how, and a dot for its state.
private struct MachineChip: View {
    let machine: MachineItem
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: machine.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(machine.title)
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .frame(width: 176, height: ConnectionPicture.row)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}
