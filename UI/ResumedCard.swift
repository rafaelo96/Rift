import SwiftUI

/// Tarjeta "Retomado en 7:07" al abrir un video conocido: dura unos segundos
/// y permite empezar desde el inicio sin pasar por un diálogo.
struct ResumedCard: View {
    let positionText: String
    let restart: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(String(format: NSLocalizedString("Resumed at %@", comment: "Video resumed at a saved time"), positionText))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .fixedSize()
            Button(action: restart) {
                Label(NSLocalizedString("Start from Beginning", comment: ""), systemImage: "backward.end.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
                    .fixedSize()
            }
            .riftGlassButton()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel(NSLocalizedString("Close", comment: ""))
            .help(NSLocalizedString("Close", comment: ""))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(VideoOverlayGlass(cornerRadius: 18))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }
}
