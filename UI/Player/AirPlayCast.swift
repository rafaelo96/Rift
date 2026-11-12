import AVKit
import Cast
import Combine
import SwiftUI

/// Envío directo por AirPlay: la TV descarga y reproduce el video ella misma
/// (HLS servido por `Core/Cast`) y Rift solo la controla. No pasa por la imagen
/// del Mac, así que la TV muestra el video original: sin Frame+, filtros ni
/// subtítulos de Rift. macOS solo enruta video de un `AVPlayer`, por eso este
/// reproductor existe aparte del pipeline; mientras no hay TV elegida está en
/// pausa y sin sonido.
@MainActor
final class AirPlayCast: ObservableObject {
    let player = AVPlayer()
    /// La TV está reproduciendo el video.
    @Published private(set) var isActive = false
    /// El archivo abierto no se puede enviar (códec sin soporte o sin índice).
    @Published private(set) var failure: String?

    /// La TV empezó (`true`) o dejó (`false`) de reproducir.
    var onActiveChange: ((Bool) -> Void)?

    private var server: CastServer?
    private var preparedURL: URL?
    private var preparedAudio: Int?
    private var observers: Set<AnyCancellable> = []

    init() {
        player.allowsExternalPlayback = true
        player.isMuted = true
        player.publisher(for: \.isExternalPlaybackActive)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self, self.isActive != active else { return }
                // Sin video preparado no hay nada que la TV pueda reproducir.
                guard !active || self.player.currentItem != nil else { return }
                self.isActive = active
                self.onActiveChange?(active)
            }
            .store(in: &observers)
    }

    var time: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    /// Deja listo el video para que la TV pueda pedirlo. Se llama al abrir el
    /// selector de AirPlay; preparar el mismo video otra vez no hace nada.
    func prepare(url: URL, audioStreamIndex: Int?, at time: Double) async {
        guard preparedURL != url || preparedAudio != audioStreamIndex || server == nil else { return }
        stopServer()
        failure = nil
        do {
            let source = try CastSource(url: url, audioStreamIndex: audioStreamIndex)
            let server = try CastServer(source: source)
            let port = try await server.start()
            guard let host = CastServer.localAddress(),
                  let playbackURL = server.playbackURL(host: host, port: port) else {
                server.stop()
                failure = String(localized: "This Mac is not connected to a network")
                return
            }
            self.server = server
            preparedURL = url
            preparedAudio = audioStreamIndex
            let item = AVPlayerItem(url: playbackURL)
            player.replaceCurrentItem(with: item)
            player.pause()
            await player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        } catch {
            player.replaceCurrentItem(with: nil)
            failure = String(localized: "This video can’t be sent over AirPlay")
        }
    }

    func play(rate: Float, volume: Float) {
        player.isMuted = false
        player.volume = volume
        player.rate = rate
    }

    func pause() { player.pause() }

    func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Cierra el envío: al cambiar o cerrar el video.
    func stop() {
        player.pause()
        player.isMuted = true
        player.replaceCurrentItem(with: nil)
        stopServer()
        if isActive {
            isActive = false
            onActiveChange?(false)
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        preparedURL = nil
        preparedAudio = nil
    }
}

/// Botón de AirPlay de Apple. Al abrirse prepara el video para la TV.
struct AirPlayRouteButton: NSViewRepresentable {
    let player: AVPlayer
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = false
        // Mismo color que los otros iconos de la barra superior: se adapta al
        // vidrio claro u oscuro. Activo (enviando a la TV) en el color de acento.
        view.setRoutePickerButtonColor(.labelColor, for: .normal)
        view.setRoutePickerButtonColor(.secondaryLabelColor, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        context.coordinator.onOpen = onOpen
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onOpen: () -> Void
        init(onOpen: @escaping () -> Void) { self.onOpen = onOpen }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onOpen() }
    }
}
