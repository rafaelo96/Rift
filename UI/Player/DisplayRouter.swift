import AppKit

/// Pantallas conectadas al Mac (incluida una TV AirPlay usada como pantalla
/// extendida) y el traslado de la ventana del reproductor entre ellas.
///
/// macOS no deja que una app inicie una conexión AirPlay de pantalla: el
/// usuario la conecta desde el Centro de control o Ajustes → Pantallas, y aquí
/// solo se detecta y se mueve el video. Rift sigue generando cada frame
/// (Frame+, subtítulos y filtros incluidos) y la TV solo lo muestra.
@MainActor
final class DisplayRouter: ObservableObject {
    struct Screen: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let isMain: Bool
    }

    @Published private(set) var screens: [Screen] = []
    /// Pantalla donde está ahora la ventana del reproductor.
    @Published private(set) var currentScreenID: CGDirectDisplayID?

    /// La ventana entró en pantalla completa al moverla aquí; al volver a la
    /// pantalla principal se sale de ella.
    private var enteredFullScreenForMove = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard AppDelegate.isPlayerWindow(note.object as? NSWindow) else { return }
                self?.refresh()
            }
        })
        refresh()
    }

    var currentScreen: Screen? { screens.first { $0.id == currentScreenID } }

    func refresh() {
        let main = NSScreen.screens.first
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Screen(id: id, name: screen.localizedName, isMain: screen == main)
        }
        currentScreenID = AppDelegate.playerWindow?.screen?.displayID
    }

    /// Lleva el video a `target`. En una pantalla externa queda en pantalla
    /// completa; de vuelta en la principal se restaura la ventana.
    func move(to target: Screen) {
        guard let window = AppDelegate.playerWindow,
              let screen = NSScreen.screens.first(where: { $0.displayID == target.id }) else { return }
        if window.screen?.displayID == target.id {
            if !target.isMain, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                enteredFullScreenForMove = true
            }
            return
        }
        let finish = { [weak self] in
            guard let self else { return }
            Self.place(window, on: screen)
            if target.isMain {
                self.enteredFullScreenForMove = false
            } else {
                // Cambiar de pantalla y pasar a pantalla completa en el mismo
                // ciclo deja la animación en la pantalla anterior.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                    self.enteredFullScreenForMove = true
                }
            }
            self.refresh()
        }
        if window.styleMask.contains(.fullScreen) {
            // Una ventana en pantalla completa no se puede mover: primero se sale.
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                MainActor.assumeIsolated { finish() }
            }
            window.toggleFullScreen(nil)
        } else {
            finish()
        }
    }

    /// Ajustes del Sistema → Pantallas, donde el menú "+" conecta una TV AirPlay.
    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Centra la ventana en `screen` con el mismo tamaño, sin pasar del área útil.
    private static func place(_ window: NSWindow, on screen: NSScreen) {
        let area = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = area.midX - frame.width / 2
        frame.origin.y = area.midY - frame.height / 2
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
