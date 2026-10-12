import SwiftUI
import AppKit

enum SubtitleBackgroundStyle: String, CaseIterable {
    case liquidGlass, color
}

enum SubtitleColors {
    static func color(_ hex: String) -> Color {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .white }
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "FFFFFF" }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

/// Shared by the player, floating PiP and Settings preview.
struct SubtitleCaption: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let text: String
    let fontSize: Double
    let textColor: Color
    let backgroundStyle: SubtitleBackgroundStyle
    let backgroundColor: Color
    let backgroundOpacity: Double

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .foregroundStyle(textColor)
            .shadow(color: .black, radius: 3, x: 0, y: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                if backgroundStyle == .liquidGlass {
                    VideoOverlayGlass(cornerRadius: 8)
                        .opacity(reduceTransparency ? 1 : backgroundOpacity)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor.opacity(backgroundOpacity))
                }
            }
    }
}
