import SwiftUI

/// Tarjeta "Siguiente" al terminar un video de la lista: cuenta regresiva de
/// 5 s con opción de reproducir ya o quedarse en este video.
struct UpNextCard: View {
    let countdown: UpNextCountdown
    let playNow: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: NSLocalizedString("Up next in %d s", comment: ""), countdown.secondsLeft))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text((countdown.title as NSString).deletingPathExtension)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
                    .help(countdown.title)
            }
            HStack(spacing: 8) {
                Button(action: playNow) {
                    Label(NSLocalizedString("Play Now", comment: ""), systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 6)
                        .fixedSize()
                }
                .riftGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)

                Button(NSLocalizedString("Cancel", comment: ""), action: cancel)
                    .font(.system(size: 12, weight: .medium))
                    .riftGlassButton()
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 260, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(VideoOverlayGlass(cornerRadius: 18))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.2), value: countdown.secondsLeft)
        .accessibilityElement(children: .contain)
    }
}
