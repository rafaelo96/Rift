import SwiftUI

/// Pantallas donde puede verse el video: la del Mac y, si está conectada, la TV
/// AirPlay. Se usa en el botón de AirPlay y en el menú Video.
struct ScreenMenuItems: View {
    @ObservedObject var state: RiftPlayerState

    var body: some View {
        let displays = state.displays
        // Con una sola pantalla también se lista: al duplicar en una TV AirPlay,
        // macOS la presenta como la única pantalla y así se ve que ya está conectada.
        if !displays.screens.isEmpty {
            ForEach(displays.screens) { screen in
                Toggle(screen.name, isOn: Binding(
                    get: { displays.currentScreenID == screen.id },
                    set: { _ in displays.move(to: screen) }
                ))
            }
            Divider()
        }
        Button(NSLocalizedString("Connect an AirPlay Display…", comment: "Opens Displays settings")) {
            displays.openDisplaySettings()
        }
    }
}

/// Salida de audio de Rift: la del sistema o una concreta (altavoz AirPlay,
/// TV, auriculares). Se usa en el menú Audio, el botón de audio y el de AirPlay.
struct AudioOutputMenu: View {
    @ObservedObject var state: RiftPlayerState

    var body: some View {
        Menu(NSLocalizedString("Audio Output", comment: "")) {
            let outputs = state.audioOutputs
            let selected = outputs.contains(state.audioOutputDeviceID) ? state.audioOutputDeviceID : nil
            Toggle(systemTitle(outputs.systemDefaultName), isOn: Binding(
                get: { selected == nil },
                set: { _ in state.setAudioOutputDevice(nil) }
            ))
            Divider()
            ForEach(outputs.devices) { device in
                Toggle(isOn: Binding(
                    get: { selected == device.id },
                    set: { _ in state.setAudioOutputDevice(device.id) }
                )) {
                    Label(device.name, systemImage: device.isAirPlay ? "airplayaudio" : "speaker.wave.2")
                }
            }
        }
    }

    private func systemTitle(_ name: String?) -> String {
        guard let name else { return NSLocalizedString("Same as System", comment: "Audio output") }
        return String(format: NSLocalizedString("Same as System (%@)", comment: "Audio output"), name)
    }
}
