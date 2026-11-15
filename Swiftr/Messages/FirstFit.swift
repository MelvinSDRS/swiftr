import SwiftUI

/// The first of its views that fits the width offered, else the last, as
/// `ViewThatFits(in: .horizontal)` picks one. Its views stay built:
/// ViewThatFits builds each of them again at every measure it hasn't kept,
/// and under the message field that was most of the work of each key typed.
/// The views not picked get no room, so each must draw nothing then
/// (`fitChoice()`).
struct FirstFit: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let pick = pick(proposal.width, subviews) else { return .zero }
        return subviews[pick].sizeThatFits(.unspecified)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let pick = pick(bounds.width, subviews)
        for (i, view) in subviews.enumerated() {
            view.place(at: bounds.origin, proposal: i == pick ? .unspecified : .zero)
        }
    }

    private func pick(_ width: CGFloat?, _ subviews: Subviews) -> Int? {
        guard !subviews.isEmpty else { return nil }
        guard let width else { return 0 }
        return subviews.firstIndex { $0.sizeThatFits(.unspecified).width <= width + 0.5 } ?? subviews.count - 1
    }
}

extension View {
    /// One of `FirstFit`'s views: as wide as it is when picked, nothing
    /// drawn when given no room.
    func fitChoice() -> some View {
        frame(minWidth: 0, minHeight: 0, alignment: .topLeading).clipped()
    }
}
