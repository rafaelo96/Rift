import SwiftUI

/// Fila "Continuar viendo" de la pantalla vacía: recientes sin terminar con
/// miniatura en la posición guardada, progreso y tiempo restante.
struct ContinueWatchingRow: View {
    let videos: [RecentVideo]
    let thumbnail: (RecentVideo) async -> CGImage?
    let open: (RecentVideo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Continue Watching", comment: ""))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 14) {
                ForEach(videos) { video in
                    ContinueWatchingCard(video: video, thumbnail: thumbnail) { open(video) }
                }
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let video: RecentVideo
    let thumbnail: (RecentVideo) async -> CGImage?
    let action: () -> Void
    @State private var image: CGImage?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard video.duration > 0 else { return 0 }
        return min(max(video.playbackPosition / video.duration, 0), 1)
    }

    private var remainingText: String {
        let minutes = max(Int(((video.duration - video.playbackPosition) / 60).rounded()), 1)
        return String(format: NSLocalizedString("%d min left", comment: "Time left in a video"), minutes)
    }

    private var displayTitle: String {
        (video.title as NSString).deletingPathExtension
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.06))
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if isHovered {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45), in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            Rectangle().fill(RiftPalette.luminousGradient)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(isHovered ? 0.3 : 0.12), lineWidth: 0.5)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(remainingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(width: 160, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.02 : 1))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(video.title)
        .accessibilityLabel(String(format: NSLocalizedString("Continue %@, %@", comment: "Continue watching card"),
                                   displayTitle, remainingText))
        .task(id: video.path) {
            let result = await thumbnail(video)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = result }
        }
    }
}
