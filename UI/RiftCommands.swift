import AppKit
import Contracts
import SwiftUI

extension Notification.Name {
    static let riftTogglePresentation = Notification.Name("RiftTogglePresentation")
    static let riftShowTechnicalInfo = Notification.Name("RiftShowTechnicalInfo")
}

/// Sigue si la ventana del reproductor es la ventana clave. Los atajos sin
/// modificador (espacio, flechas, M, H, 1–4) solo se activan entonces, para no
/// robar teclas a los campos de texto de Ajustes o a los paneles de apertura.
@MainActor
final class PlayerWindowFocus: ObservableObject {
    @Published private(set) var isPlayerKey = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        isPlayerKey = AppDelegate.isPlayerWindow(NSApp.keyWindow)
    }
}

/// Barra de menús de Rift: todo comando del reproductor es visible aquí con su atajo.
struct RiftCommands: Commands {
    @ObservedObject var state: RiftPlayerState
    @ObservedObject var focus: PlayerWindowFocus

    private static let rates: [Float] = [1, 1.5, 2, 0.5]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { state.openVideo() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(state.recentVideos) { video in
                    Button(video.title) { state.loadVideo(video.url) }
                }
                Divider()
                Button("Clear Menu") { state.clearRecentVideos() }
                    .disabled(state.recentVideos.isEmpty)
            }
            Button("Add to Playlist…") { state.addVideosToPlaylist() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Load Subtitle File…") { state.openExternalSubtitles() }
                .disabled(!state.hasVideo)
            Divider()
            Button("Close Video") { state.closeVideo() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!state.hasVideo)
        }

        CommandMenu("Playback") {
            let enabled = state.hasVideo && focus.isPlayerKey
            Button(state.isPlaying ? "Pause" : "Play") {
                state.togglePlay()
                state.showFeedback(state.isPlaying ? .play : .pause)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!enabled)

            Divider()
            seekButton("Skip Back 10 Seconds", delta: -10, key: .leftArrow, modifiers: [], enabled: enabled)
            seekButton("Skip Forward 10 Seconds", delta: 10, key: .rightArrow, modifiers: [], enabled: enabled)
            seekButton("Skip Back 1 Minute", delta: -60, key: .leftArrow, modifiers: .shift, enabled: enabled)
            seekButton("Skip Forward 1 Minute", delta: 60, key: .rightArrow, modifiers: .shift, enabled: enabled)
            Button("Previous Video") { state.playPreviousPlaylistItem() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(state.previousPlaylistItem == nil)
            Button("Next Video") { state.playNextPlaylistItem() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(state.nextPlaylistItem == nil)
            Button("Add Marker") { state.addMarker() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!state.hasVideo)

            Divider()
            Button("Volume Up") { changeVolume(by: 0.05) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!enabled)
            Button("Volume Down") { changeVolume(by: -0.05) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!enabled)
            Button(state.volume > 0 ? "Mute" : "Unmute") {
                state.setVolume(state.volume > 0 ? 0 : 0.72)
                state.showFeedback(.volume(state.volume))
            }
            .keyboardShortcut("m", modifiers: [])
            .disabled(!enabled)

            Divider()
            Menu("Speed") {
                ForEach(Array(Self.rates.enumerated()), id: \.offset) { index, rate in
                    Toggle(rateTitle(rate), isOn: Binding(
                        get: { abs(state.playbackRate - rate) < 0.001 },
                        set: { _ in
                            state.playbackRate = rate
                            state.showFeedback(.rate(rate))
                        }
                    ))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .disabled(!enabled)
                }
            }

            Divider()
            Toggle("Frame+", isOn: Binding(
                get: { state.interpolationMode != .disabled },
                set: { state.setInterpolationMode($0 ? .motion4x : .disabled) }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Maximum Fluidity", isOn: Binding(
                get: { state.maximumFluidity },
                set: { state.setMaximumFluidity($0) }
            ))
            Toggle("Super Resolution", isOn: Binding(
                get: { state.superResolutionMode != .off },
                set: { state.setSuperResolutionMode($0 ? .strong : .off) }
            ))
            .keyboardShortcut("u", modifiers: [.command, .option])

            Divider()
            Button(state.isPictureInPictureActive ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                state.togglePictureInPicture()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!state.isPictureInPictureAvailable)
            Menu("Picture in Picture Automatically") {
                Toggle("When Minimized", isOn: $state.automaticPiPOnMinimize)
                Toggle("When Switching Apps", isOn: $state.automaticPiPOnAppSwitch)
            }
        }

        CommandGroup(before: .toolbar) {
            Button(state.areControlsVisible ? "Hide Controls" : "Show Controls") {
                withAnimation { state.areControlsVisible.toggle() }
            }
            .keyboardShortcut("h", modifiers: [])
            .disabled(!(state.hasVideo && focus.isPlayerKey))
            Button("Toggle Fit / Fill") {
                NotificationCenter.default.post(name: .riftTogglePresentation, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!state.hasVideo)
            Button("Technical Info") {
                NotificationCenter.default.post(name: .riftShowTechnicalInfo, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(state.technicalInfo == nil)
            Divider()
        }
    }

    private func seekButton(_ title: LocalizedStringKey, delta: Double, key: KeyEquivalent,
                            modifiers: EventModifiers, enabled: Bool) -> some View {
        Button(title) {
            state.seek(by: delta)
            state.showFeedback(.seek(delta))
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(!enabled)
    }

    private func changeVolume(by delta: Double) {
        state.setVolume(state.volume + delta)
        state.showFeedback(.volume(state.volume))
    }

    private func rateTitle(_ rate: Float) -> String {
        rate == 1 ? String(localized: "Normal") : rate.formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}
