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
        ZStack {
            NativeVisualEffectView(material: .hudWindow, blendingMode: blendingMode)
                .opacity(max(effectOpacity, 0.72))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(0.20))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .white.opacity(0.025), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Liquid Glass Panel

struct LiquidGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(GlassBackground(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
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

    @ViewBuilder
    func riftGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
