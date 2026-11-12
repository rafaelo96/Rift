import SwiftUI
import Contracts

/// Uses the player's preference setters so Settings and transport controls agree.
struct RiftSettingsView: View {
    @ObservedObject var state: RiftPlayerState

    var body: some View {
        TabView {
            playback
                .tabItem { Label("Reproducción", systemImage: "play.circle") }
            subtitles
                .tabItem { Label("Subtítulos", systemImage: "captions.bubble") }
            framePlus
                .tabItem { Label("Frame+", systemImage: "sparkles.tv") }
            pictureInPicture
                .tabItem { Label("PiP", systemImage: "pip") }
        }
        .padding(20)
        .frame(width: 580, height: 490)
    }

    private var playback: some View {
        Form {
            Section {
                Toggle("Reabrir el último video al iniciar", isOn: $state.reopenLastVideoOnLaunch)
                Picker("Al abrir un video conocido", selection: $state.openingBehavior) {
                    Text("Preguntar").tag(PlaybackOpeningBehavior.ask)
                    Text("Continuar automáticamente").tag(PlaybackOpeningBehavior.resume)
                    Text("Empezar desde el principio").tag(PlaybackOpeningBehavior.restart)
                }
                Toggle("Recordar audio y subtítulos por archivo", isOn: $state.rememberTrackSelections)
                Picker("Desfase de audio", selection: Binding(
                    get: { state.audioSyncOffset }, set: state.setAudioSyncOffset
                )) {
                    ForEach([-2.0, -1, -0.5, -0.25, -0.1, 0, 0.1, 0.25, 0.5, 1, 2], id: \.self) { offset in
                        Text(offset == 0 ? "Sin desfase" : String(format: "%+.2f s", offset)).tag(offset)
                    }
                }
            } footer: {
                Text("Los cambios se aplican al video actual y se conservan para próximas sesiones.")
            }
            Button("Restablecer reproducción") {
                state.reopenLastVideoOnLaunch = false
                state.openingBehavior = .resume
                state.rememberTrackSelections = true
                state.setAudioSyncOffset(0)
            }
        }
        .formStyle(.grouped)
    }

    private var subtitles: some View {
        Form {
            Section {
                Toggle("Activar subtítulos al abrir un video nuevo", isOn: $state.subtitlesEnabledByDefault)
                Slider(value: $state.subtitleFontSize, in: 16...48, step: 1) {
                    Text("Tamaño: \(Int(state.subtitleFontSize)) pt")
                }
                Slider(value: $state.subtitleBottomInset, in: 20...140, step: 1) {
                    Text("Distancia desde abajo: \(Int(state.subtitleBottomInset)) pt")
                }
                ColorPicker("Color del texto", selection: Binding(
                    get: { SubtitleColors.color(state.subtitleTextColorHex) },
                    set: { state.subtitleTextColorHex = SubtitleColors.hex($0) }), supportsOpacity: false)
                Picker("Fondo", selection: $state.subtitleBackgroundStyle) {
                    Text("Liquid Glass").tag(SubtitleBackgroundStyle.liquidGlass)
                    Text("Color").tag(SubtitleBackgroundStyle.color)
                }
                if state.subtitleBackgroundStyle == .color {
                    ColorPicker("Color del fondo", selection: Binding(
                        get: { SubtitleColors.color(state.subtitleBackgroundColorHex) },
                        set: { state.subtitleBackgroundColorHex = SubtitleColors.hex($0) }), supportsOpacity: false)
                }
                Slider(value: $state.subtitleBackgroundOpacity, in: 0...1, step: 0.05) {
                    Text("Opacidad del fondo: \(Int(state.subtitleBackgroundOpacity * 100)) %")
                }
            } footer: {
                Text("La apariencia se aplica al reproductor, a pantalla completa y a PiP. Los controles visibles reservan espacio para no cubrir los subtítulos. Las elecciones guardadas por archivo tienen prioridad sobre la activación predeterminada.")
            }
            Section("Vista previa") {
                SubtitleCaption(text: String(localized: "Así se verán tus subtítulos"), fontSize: state.subtitleFontSize,
                    textColor: SubtitleColors.color(state.subtitleTextColorHex),
                    backgroundStyle: state.subtitleBackgroundStyle,
                    backgroundColor: SubtitleColors.color(state.subtitleBackgroundColorHex),
                    backgroundOpacity: state.subtitleBackgroundOpacity)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Section {
                LabeledContent("Desfase") {
                    HStack(spacing: 8) {
                        TextField("Desfase en segundos", value: Binding(get: { state.subtitleDelay }, set: { value in
                            if value.isFinite { state.subtitleDelay = min(max(value, -10), 10) }
                        }), format: .number.precision(.fractionLength(2)))
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 85)
                        Text("s")
                            .fixedSize()
                        Stepper("Ajustar desfase", value: $state.subtitleDelay, in: -10...10, step: 0.1)
                            .labelsHidden()
                            .fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            } footer: {
                Text("Un valor positivo retrasa los subtítulos. Se aplica también en PiP.")
            }
            Button("Restablecer subtítulos") {
                state.subtitlesEnabledByDefault = true
                state.subtitleBackgroundStyle = .liquidGlass
                state.subtitleTextColorHex = "FFFFFF"
                state.subtitleBackgroundColorHex = "000000"
                state.subtitleFontSize = 28
                state.subtitleBottomInset = 58
                state.subtitleBackgroundOpacity = 0.72
                state.subtitleDelay = 0
            }
        }
        .formStyle(.grouped)
    }

    private var framePlus: some View {
        Form {
            Section {
                Toggle("Activar Frame+", isOn: Binding(
                    get: { state.requestedInterpolationMode != .disabled },
                    set: { state.setInterpolationMode($0 ? .enabled : .disabled) }
                ))
            } footer: {
                Text("Aumenta la fluidez durante la reproducción. Rift adapta el trabajo a la capacidad medida de tu Mac; pueden aparecer artefactos en movimientos rápidos.")
            }
            Section {
                LabeledContent("Chip", value: RiftPlayerState.chipName)
                if state.sessionQualityByResolution.isEmpty {
                    Text("Aún sin medir. Rift mide tu Mac la primera vez que reproduces con Frame+.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.sessionQualityByResolution.sorted { $0.key > $1.key }, id: \.key) { resolution, quality in
                        LabeledContent(resolution.replacingOccurrences(of: "x", with: "×"),
                                       value: Self.qualityName(quality))
                    }
                }
            } header: {
                Text("Medición en este Mac")
            } footer: {
                Text("Es el tamaño en el que Frame+ analiza el movimiento; el video siempre se muestra en su resolución completa. Rift elige el mayor que tu Mac sostiene a 60 fps y lo vuelve a medir cada vez que se abre, porque la capacidad real cambia con la temperatura y lo que esté haciendo tu Mac.")
            }
            Section {
                Toggle("Fluidez máxima", isOn: Binding(
                    get: { state.maximumFluidity },
                    set: { state.setMaximumFluidity($0) }
                ))
                .disabled(state.requestedInterpolationMode == .disabled)
            } footer: {
                Text("Interpola también los cambios de pose y los dibujos repetidos tres veces. Más fluido, con más artefactos en escenas de acción.")
            }
            Section {
                Toggle("Superresolución", isOn: Binding(
                    get: { state.superResolutionMode != .off },
                    set: { state.setSuperResolutionMode($0 ? .strong : .off) }
                ))
            } footer: {
                Text("Realza el detalle al ampliar el video. Es independiente de Frame+.")
            }
            Button("Restablecer Frame+ y superresolución") {
                state.setInterpolationMode(.disabled)
                state.setMaximumFluidity(false)
                state.setSuperResolutionMode(.off)
            }
        }
        .formStyle(.grouped)
    }

    /// "Análisis ligero (768×320)": la calidad es el plano donde Frame+ estima
    /// el movimiento, no la resolución con la que se ve el video.
    private static func qualityName(_ quality: Int) -> String {
        let size = RiftPlayerState.analysisPlaneSize(forQuality: quality)
        let level: String
        switch quality {
        case 2: level = String(localized: "Análisis detallado")
        case 1: level = String(localized: "Análisis equilibrado")
        default: level = String(localized: "Análisis ligero")
        }
        return "\(level) (\(size))"
    }

    private var pictureInPicture: some View {
        Form {
            Section {
                Toggle("Activar al minimizar el reproductor", isOn: $state.automaticPiPOnMinimize)
                Toggle("Activar al cambiar de aplicación", isOn: $state.automaticPiPOnAppSwitch)
            } footer: {
                Text("Se activa automáticamente mientras el video se reproduce. Al volver a Rift, el video regresa si PiP se abrió automáticamente.")
            }
            Section {
                Text("PiP abre en la esquina superior derecha y permite mover y redimensionar la ventana.")
                Text("Regresar restaura el reproductor y mantiene la reproducción. Cerrar PiP pausa el video sin abrir la ventana principal.")
                    .foregroundStyle(.secondary)
            }
            Button("Restablecer PiP") {
                state.automaticPiPOnMinimize = true
                state.automaticPiPOnAppSwitch = false
            }
        }
        .formStyle(.grouped)
    }
}
