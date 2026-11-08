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
            NativeVisualEffectView(material: .underWindowBackground, blendingMode: blendingMode)
                .opacity(max(effectOpacity, 0.34))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(0.055))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.065), .white.opacity(0.012), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Liquid Glass Panel

/// Glass for surfaces above video; window and recovery backgrounds keep their own material.
struct VideoOverlayGlass: View {
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                // Sin .opacity encima: atenuar el vidrio lo enturbia y le quita
                // la refracción; el material regular ya es legible sobre video.
                Color.clear
                    .glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
            }
        }
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(.white.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

/// Agrupa varios elementos de vidrio para que el sistema los combine y los
/// transforme juntos (macOS 26+); en versiones anteriores no hace nada.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct LiquidGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(VideoOverlayGlass(cornerRadius: cornerRadius))
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
