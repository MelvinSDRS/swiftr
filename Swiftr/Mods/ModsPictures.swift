import AppKit
import HerdrKit
import ModKit
import SwiftUI

/// Swiftr's window in small with a layout's parts in it, as `MiniWindow`
/// draws the window for other settings: the sidebar, the tab's card, and
/// the layout's mods in the accent color, each where the layout puts it.
/// A mod the person doesn't have shows faint in a dashed frame.
struct LayoutPicture: View {
    var dark: Bool
    var theme: TerminalTheme
    /// Nil: the tab alone.
    var layout: WindowLayout?
    /// The mods the person has.
    var has: Set<String>
    /// How Swiftr's own layout shows its sidebar.
    var sidebar = ModSidebarStyle.floating

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
        let unit = min(sx, sy)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
        }
        func fill(_ r: CGRect, _ radius: CGFloat, _ color: Color) {
            g.fill(Path(roundedRect: r, cornerRadius: radius * unit, style: .continuous), with: .color(color))
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

        // The window and Swiftr's own sidebar, which every layout keeps.
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(white: 0.17) : Color(white: 0.9)))
        let lights = [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)]
        for (i, color) in lights.enumerated() {
            dot(6.5 + CGFloat(i) * 5, 6, 3.3, color)
        }
        bar(5.5, 15, 12, ink.opacity(0.28), height: 1.6)
        for (i, width) in [CGFloat(18), 14, 20].enumerated() {
            let y = 20.5 + CGFloat(i) * 6
            if i == 0 { fill(box(2.5, y - 2.9, 33, 5.8), 1.8, ink.opacity(0.1)) }
            fill(box(5.5, y - 1.6, 3.2, 3.2), 0.9, ink.opacity(0.3))
            bar(11, y, width, ink.opacity(0.45))
        }
        fill(box(4, 37.5, 30, 0.5), 0, ink.opacity(0.15))
        bar(5.5, 43, 12, ink.opacity(0.28), height: 1.6)
        for (i, width) in [CGFloat(17), 13, 19].enumerated() {
            let y = 48.5 + CGFloat(i) * 6
            dot(7.1, y, 2.6, ink.opacity(0.3))
            bar(11, y, width, ink.opacity(0.45))
        }

        // In grid units: the tab's card, with a shell's lines.
        func card(_ r: CGRect) {
            let shape = Path(roundedRect: box(r.minX, r.minY, r.width, r.height), cornerRadius: 4 * unit, style: .continuous)
            g.fill(shape, with: .color(theme.pictureBackground))
            g.stroke(shape, with: .color(dark ? .white.opacity(0.1) : .black.opacity(0.12)), lineWidth: 0.5)
            guard r.width > 22, r.height > 22 else { return }
            let x = r.minX + 5, y = r.minY + 7, room = r.width - 10
            bar(x, y, 4, theme.pictureColor(2))
            bar(x + 6, y, min(22, room - 6), fg.opacity(0.85))
            bar(x, y + 6, min(30, room), fg.opacity(0.55))
            bar(x, y + 12, min(22, room), fg.opacity(0.55))
            bar(x, y + 18, min(34, room), fg.opacity(0.55))
            bar(x, y + 24, 4, theme.pictureColor(2))
            fill(box(x + 6, y + 22, 2.6, 4), 0.3, Color(nsColor: theme.cursorColor))
        }
        // A mod's panel or bar; `tabs`: how many mods share it, and which shows.
        /// `flat`: on the window's own surface, as the mods' sidebar is.
        func panel(_ r: CGRect, here: Bool, tabs: Int = 1, chosen: Int = 0, flat: Bool = false) {
            let frame = box(r.minX, r.minY, r.width, r.height)
            let shape = Path(roundedRect: frame, cornerRadius: 3 * unit, style: .continuous)
            guard here else {
                g.stroke(shape, with: .color(ink.opacity(0.3)), style: StrokeStyle(lineWidth: 0.8, dash: [2.5, 2]))
                return
            }
            if !flat {
                g.fill(shape, with: .color(accent.opacity(0.18)))
                g.stroke(shape, with: .color(accent.opacity(0.55)), lineWidth: 0.6)
            }
            let tall = r.height > 12
            var y = r.minY + (tall ? 5 : r.height / 2)
            let x = r.minX + 3.5, room = r.width - 7
            guard room > 4 else { return }
            if tabs > 1, tall {
                // The mods that share the panel, the shown one marked.
                let width = min(7, (room - CGFloat(tabs - 1) * 1.5) / CGFloat(tabs))
                for i in 0 ..< tabs {
                    bar(x + CGFloat(i) * (width + 1.5), y, width, accent.opacity(i == chosen ? 0.95 : 0.4), height: 2.2)
                }
                y += 6
            }
            if !tall {
                bar(x, y, min(room * 0.3, 14), accent.opacity(0.85), height: 1.8)
                if room > 40 { bar(x + 18, y, min(room * 0.2, 10), accent.opacity(0.5), height: 1.8) }
                return
            }
            for (i, share) in [CGFloat(0.8), 0.55, 0.7, 0.4].enumerated() where y + CGFloat(i) * 5.5 < r.maxY - 3 {
                bar(x, y + CGFloat(i) * 5.5, room * share, accent.opacity(i == 0 ? 0.85 : 0.5), height: 1.8)
            }
        }
        func knows(_ item: WindowLayout.Item) -> Bool {
            if case .mod(let name) = item.content { return has.contains(name) }
            return false
        }

        // The layout's tree, in the room right of the sidebar: a window
        // about 1000 × 700 points, so a panel keeps its share of it.
        let room = CGRect(x: 40, y: 3, width: 85, height: 74)
        func place(_ item: WindowLayout.Item, _ r: CGRect) {
            switch item.kind {
            case .block:
                switch item.content {
                case .tab: card(r)
                case .mod: panel(r, here: knows(item))
                default: break
                }
            case .stack:
                let shown = item.shownChild
                let mods = item.children.filter(knows)
                panel(r, here: shown.map(knows) ?? false, tabs: mods.count, chosen: mods.firstIndex { $0.id == shown?.id } ?? 0)
            case .row, .column:
                let across = item.kind == .row
                let parts = item.children.filter { WindowLayout.shows($0) && !$0.hidden }
                guard !parts.isEmpty else { return }
                let gap: CGFloat = 1.6
                let length = (across ? r.width : r.height) - gap * CGFloat(parts.count - 1)
                let scale = across ? room.width / 1000 : room.height / 700
                let fixed = parts.map { part in part.px.map { max(CGFloat($0) * scale, 4.5) } }
                let taken = fixed.compactMap(\.self).reduce(0, +)
                let weights = parts.enumerated().filter { fixed[$0.offset] == nil }.map { CGFloat($0.element.weight) }.reduce(0, +)
                let squeeze = weights == 0 || taken > length * 0.75 ? (taken > 0 ? length * (weights == 0 ? 1 : 0.75) / taken : 1) : 1
                let rest = max(0, length - taken * squeeze)
                var at = across ? r.minX : r.minY
                for (index, part) in parts.enumerated() {
                    let own = fixed[index].map { $0 * squeeze } ?? (weights > 0 ? rest * CGFloat(part.weight) / weights : 0)
                    place(part, across ? CGRect(x: at, y: r.minY, width: own, height: r.height) : CGRect(x: r.minX, y: at, width: r.width, height: own))
                    at += own + gap
                }
            }
        }
        if let layout, layout.isOwn, let stack = layout.find(WindowLayout.panelStackID), let side = layout.find(WindowLayout.panelID) {
            // Swiftr's own: the mods in a sidebar on the window's right.
            let mods = stack.children.filter(knows)
            guard !mods.isEmpty, !side.hidden else { return card(room) }
            let width = max(CGFloat(side.px ?? 340) * room.width / 1000, 24)
            let chosen = mods.firstIndex { $0.id == stack.shownChild?.id } ?? 0
            let edge: Color = dark ? .white.opacity(0.16) : .black.opacity(0.14)
            switch sidebar {
            case .card:
                // A card of its own, beside the tab's.
                card(CGRect(x: room.minX, y: room.minY, width: room.width - width - 2.4, height: room.height))
                let own = CGRect(x: room.maxX - width, y: room.minY, width: width, height: room.height)
                let shape = Path(roundedRect: box(own.minX, own.minY, own.width, own.height), cornerRadius: 4 * unit, style: .continuous)
                g.fill(shape, with: .color(theme.pictureBackground))
                g.stroke(shape, with: .color(dark ? .white.opacity(0.1) : .black.opacity(0.12)), lineWidth: 0.5)
                panel(own, here: true, tabs: mods.count, chosen: chosen, flat: true)
            case .floating:
                // A lifted panel on the tab's card, which keeps its width.
                card(room)
                let own = CGRect(x: room.maxX - width - 2.5, y: room.minY + 2.5, width: width, height: room.height - 5)
                let shape = Path(roundedRect: box(own.minX, own.minY, own.width, own.height), cornerRadius: 3.5 * unit, style: .continuous)
                g.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 3 * unit, y: 1 * unit))
                    layer.fill(shape, with: .color(theme.pictureBackground))
                }
                if theme.isDark { g.fill(shape, with: .color(.white.opacity(0.09))) }
                g.stroke(shape, with: .color(edge), lineWidth: 0.5)
                panel(own, here: true, tabs: mods.count, chosen: chosen, flat: true)
            }
        } else if let layout, WindowLayout.shows(layout.root) {
            place(layout.root, room)
        } else {
            card(room)
        }
    }
}

/// The mods' sidebar in one of its styles, for the Appearance settings:
/// Swiftr's window in small with two mods in the sidebar.
struct ModSidebarPicture: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let style: ModSidebarStyle

    private static let sample = WindowLayout.own(mods: ["changes", "mod"], width: 330)

    var body: some View {
        LayoutPicture(dark: scheme == .dark, theme: model.prefs.theme, layout: Self.sample, has: ["changes", "mod"], sidebar: style)
    }
}

/// A mod's own icon (`<name>.svg` in its folder), else a puzzle piece.
struct ModIcon: View {
    let name: String
    /// Changes when the mod's files do.
    let revision: Int

    private static var cache: [String: NSImage?] = [:]

    var body: some View {
        if let image = Self.image(name, revision) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "puzzlepiece.extension")
        }
    }

    private static func image(_ name: String, _ revision: Int) -> NSImage? {
        let key = "\(name)#\(revision)"
        if let hit = cache[key] { return hit }
        let file = Mods.shared.center.modsFolder.appending(path: "\(name)/\(name).svg")
        let image = NSImage(contentsOf: file)
        // Drawn in the row's color, as herdr-app draws `currentColor`.
        image?.isTemplate = true
        if cache.count > 200 { cache = [:] }
        cache[key] = image
        return image
    }
}
