#if DEBUG
import AppKit
import HerdrKit

/// Debug builds only: what `DebugHooks` runs for "updates:…", and what its
/// dump says about updates.
enum UpdateHooks {
    /// check | all | app | hours=<n> | offer=<version> (a Swiftr version on offer, without a feed; nothing after = none)
    /// | click=<title> (a button of one of Sparkle's windows, by its title)
    static func run(_ command: String, _ model: AppModel) {
        let center = model.updateCenter!
        let pair = command.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch pair[0] {
        case "check": center.checkNow()
        case "all": center.updateAll()
        case "app": center.app.install()
        case "hours": center.hours = Int(pair.last ?? "") ?? UpdateSchedule.standard
        case "offer": center.app.debugOffer(pair.count > 1 && !pair[1].isEmpty ? pair[1] : nil)
        case "click":
            for button in sparkleButtons() where button.title == pair.last { button.performClick(nil) }
        default: break
        }
    }

    static func dump(_ model: AppModel) -> [String: Any] {
        let center = model.updateCenter!
        let app = center.app
        return [
            "way": String(describing: app.way), "version": AppUpdate.version, "build": AppUpdate.build,
            "latest": app.latest ?? "", "blocked": app.blocked ?? "", "appChecking": app.checking,
            "appError": app.checkError ?? "", "step": app.step.map { String(describing: $0) } ?? "",
            "checking": center.checking, "checkedAt": center.checkedAt.map { $0.timeIntervalSince1970 } ?? 0,
            "hours": center.hours, "count": center.count, "busy": center.busy, "updatingAll": center.updatingAll,
            "core": center.coreOffer ?? "", "coreError": model.updates.checkError ?? "",
            "machines": center.machines.map(\.name), "models": center.modelOffers.map(\.key),
            "sparkle": sparkleWindows().map { window in
                ["title": window.title, "buttons": buttons(in: window).map(\.title), "texts": texts(in: window)] as [String: Any]
            },
        ]
    }

    /// Sparkle's windows: its controllers' class names start with SU or SPU.
    private static func sparkleWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard window.isVisible, let controller = window.windowController else { return false }
            let name = String(describing: type(of: controller))
            return name.hasPrefix("SU") || name.hasPrefix("SPU")
        }
    }

    private static func sparkleButtons() -> [NSButton] {
        sparkleWindows().flatMap(buttons)
    }

    private static func buttons(in window: NSWindow) -> [NSButton] {
        views(in: window.contentView).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
    }

    private static func texts(in window: NSWindow) -> [String] {
        views(in: window.contentView).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
    }

    private static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }
}
#endif
