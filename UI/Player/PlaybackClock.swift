import Combine

/// Tiempo de reproducción y fps mostrados, aparte de `RiftPlayerState`.
///
/// Cambian 10 veces por segundo; si fueran `@Published` del estado, cada cambio
/// haría recalcular toda la ventana. Aquí solo los observan la línea de tiempo,
/// el indicador de fps y el PiP.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var renderingFPS: Double = 24
}
