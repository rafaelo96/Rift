import AppKit
import SwiftUI

enum RiftPalette {
    static let cyan = Color(red: 0.22, green: 0.78, blue: 0.96)
    static let blue = Color(red: 0.043, green: 0.55, blue: 0.965)
    static let deepBlue = Color(red: 0.027, green: 0.35, blue: 0.96)
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
            NativeVisualEffectView(
                material: .underWindowBackground,
                blendingMode: blendingMode
            )
            .opacity(effectOpacity)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(0.006))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.010))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(RiftPalette.blue.opacity(0.010))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.095), .white.opacity(0.018), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(height: cornerRadius * 1.7)
                        .blur(radius: 8)
                }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.24), lineWidth: 0.5)
                .padding(1)
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(height: cornerRadius * 1.45)
                        .blur(radius: 5)
                }
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
            .shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 10)
            .shadow(color: .white.opacity(0.035), radius: 1, x: 0, y: -1)
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
                        ? RiftPalette.cyan.opacity(0.10)
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
