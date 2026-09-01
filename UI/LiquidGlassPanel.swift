import AppKit
import SwiftUI

// MARK: - Glass Background

struct GlassBackground: View {
    var cornerRadius: CGFloat = 16
    var blendsWithWindow: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.black.opacity(0.18))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.06),
                                .white.opacity(0.015),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
    }
}

// MARK: - Liquid Glass Panel

struct LiquidGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var blendsWithWindow: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(GlassBackground(cornerRadius: cornerRadius, blendsWithWindow: blendsWithWindow))
            .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Glass Button Modifier

struct GlassButtonStyle: ViewModifier {
    @State private var isHovered = false
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered
                        ? Color(red: 0.40, green: 0.65, blue: 1.0).opacity(0.08)
                        : .clear)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    func glassButton(cornerRadius: CGFloat = 8) -> some View {
        modifier(GlassButtonStyle(cornerRadius: cornerRadius))
    }
}