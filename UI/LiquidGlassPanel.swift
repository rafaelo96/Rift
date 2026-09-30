import AppKit
import SwiftUI

enum RiftPalette {
    static let cyan = Color.accentColor
    static let blue = Color.accentColor
    static let deepBlue = Color.accentColor
    static let midnight = Color(red: 0.008, green: 0.034, blue: 0.075)
    static let luminousGradient = LinearGradient(
        colors: [cyan, blue, deepBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Glass Background

struct GlassBackground: View {
    var cornerRadius: CGFloat = 16
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var effectOpacity: Double = 0.16

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
            }
    }
}

// MARK: - Liquid Glass Panel

struct LiquidGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(GlassBackground(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
    }
}

// MARK: - Glass Button Modifier

struct GlassButtonStyle: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
    }
}

extension View {
    func glassButton(cornerRadius: CGFloat = 8) -> some View {
        modifier(GlassButtonStyle(cornerRadius: cornerRadius))
    }
}
