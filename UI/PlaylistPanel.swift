import SwiftUI

/// Panel lateral de la lista de reproducción (tecla L): miniatura, duración y
/// progreso de cada video; doble clic o ⏎ reproduce, arrastrar reordena y ⌫ quita.
struct PlaylistPanel: View {
    @ObservedObject var state: RiftPlayerState
    @State private var selection: PlaylistItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.5)

            if state.playlist.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 330)
        .frame(maxHeight: .infinity)
        .background(VideoOverlayGlass(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .onHover { hovering in
            // Como la barra de controles: el cursor y los controles no se
            // ocultan mientras el puntero está sobre el panel.
            hovering ? state.stopHideTimer() : state.startHideTimer()
        }
        .onAppear { selection = state.activePlaylistItemID }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(NSLocalizedString("Playlist", comment: ""))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(state.playlist.count == 1
                     ? NSLocalizedString("1 video", comment: "Playlist with one item")
                     : String(format: NSLocalizedString("%d videos", comment: "Playlist item count"), state.playlist.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            Spacer()
            // Solo el ícono, para que el título quepa en una línea.
            Button {
                state.addVideosToPlaylist()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .riftGlassButton()
            .accessibilityLabel(NSLocalizedString("Add to Playlist…", comment: ""))
            .help(NSLocalizedString("Add to Playlist…", comment: ""))

            Button {
                state.togglePlaylistPanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .accessibilityLabel(NSLocalizedString("Hide Playlist", comment: ""))
            .help(NSLocalizedString("Hide Playlist", comment: ""))
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(state.playlist) { item in
                PlaylistRow(item: item,
                            record: state.recentRecord(for: item),
                            isPlaying: item.id == state.activePlaylistItemID,
                            thumbnail: { url, time in await state.thumbnail(for: url, at: time) })
                    .tag(item.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { state.movePlaylistItems(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: PlaylistItem.ID.self) { ids in
            if let item = playlistItem(ids.first) {
                Button(NSLocalizedString("Play", comment: "")) { state.playPlaylistItem(item) }
                Button(NSLocalizedString("Play from Beginning", comment: "")) {
                    state.playPlaylistItem(item, fromStart: true)
                }
                Divider()
                Button(NSLocalizedString("Show in Finder", comment: "")) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Button(NSLocalizedString("Remove from Playlist", comment: ""), role: .destructive) {
                    remove(item)
                }
            }
        } primaryAction: { ids in
            if let item = playlistItem(ids.first) { state.playPlaylistItem(item) }
        }
        .onDeleteCommand {
            if let item = playlistItem(selection) { remove(item) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.4))
            Text(NSLocalizedString("The playlist is empty", comment: ""))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playlistItem(_ id: PlaylistItem.ID?) -> PlaylistItem? {
        guard let id else { return nil }
        return state.playlist.first { $0.id == id }
    }

    private func remove(_ item: PlaylistItem) {
        let index = state.playlist.firstIndex(of: item)
        state.removeFromPlaylist(item)
        // La selección pasa al siguiente para poder quitar varios seguidos con ⌫.
        if let index, !state.playlist.isEmpty {
            selection = state.playlist[min(index, state.playlist.count - 1)].id
        }
    }
}

private struct PlaylistRow: View {
    let item: PlaylistItem
    let record: RecentVideo?
    let isPlaying: Bool
    let thumbnail: (URL, Double) async -> CGImage?
    @State private var image: CGImage?

    private var progress: Double? {
        guard let record, record.duration > 0, record.playbackPosition > 1 else { return nil }
        return min(record.playbackPosition / record.duration, 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.white.opacity(0.06))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            Rectangle().fill(RiftPalette.luminousGradient)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RiftPalette.luminousGradient)
                        Text(NSLocalizedString("Now Playing", comment: ""))
                    } else if let record, record.duration > 0 {
                        Text(PlaybackTimeFormat.string(record.duration))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(item.url.lastPathComponent)
        .accessibilityElement(children: .combine)
        .task(id: item.path) {
            // Sin posición guardada, un frame a los 60 s evita el negro inicial.
            let time = record.map { $0.playbackPosition > 1 ? $0.playbackPosition : 60 } ?? 60
            let result = await thumbnail(item.url, time)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
