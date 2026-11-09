import SwiftUI

/// Dos vistas, una pegada a cada borde, dejando libre un hueco central
/// (donde otra capa dibuja los controles de transporte centrados).
/// El ancho ideal es `2 × lado más ancho + hueco`, de modo que
/// `ViewThatFits` pase a la variante compacta antes de que un lado invada el centro.
struct SymmetricSidesLayout: Layout {
    let centerWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let side = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).max() ?? 0
        let ideal = 2 * side + centerWidth
        return CGSize(width: max(proposal.width ?? ideal, ideal), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        if subviews.count > 1, let last = subviews.last {
            last.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        }
    }
}
