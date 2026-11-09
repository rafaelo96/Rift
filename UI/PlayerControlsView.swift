import SwiftUI
import Contracts
import Decode

struct PlayerControlsView<PlayerStateType: PlayerStateProviding>: View {
    @ObservedObject var state: PlayerStateType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDraggingSlider = false
    @State private var dragSliderValue: Double = 0
    @State private var showVisualPanel = false

    var body: some View {
        LiquidGlassPanel(cornerRadius: 32) {
            VStack(spacing: 10) {
                timeline
                    .padding(.horizontal, 4)

                ZStack {
                    // En ventanas estrechas las opciones muestran solo el ícono
                    // en vez de desbordar la barra por ambos lados.
                    ViewThatFits(in: .horizontal) {
                        controlRow(compactOptions: false)
                        controlRow(compactOptions: true)
                    }

                    transportControls
                        .frame(width: 176)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 1080)
        .animation(surfaceAnimation, value: state.isPlaying)
        .animation(surfaceAnimation, value: state.playbackRate)
        .animation(surfaceAnimation, value: state.fpsMode)
        .animation(surfaceAnimation, value: state.interpolationMode)
        .animation(surfaceAnimation, value: state.audioTracks.count)
        .onHover { isHovering in
            if isHovering {
                state.stopHideTimer()
            } else {
                state.startHideTimer()
            }
        }
    }

    /// ⏮ ⏭ van en los extremos de la línea de tiempo y solo con lista: en la
    /// fila de controles le quitarían el texto a las opciones en la ventana normal.
    private var showsPlaylistSteps: Bool {
        ((state as? RiftPlayerState)?.playlist.count ?? 0) > 1
    }

    private func controlRow(compactOptions: Bool) -> some View {
        // Los controles de transporte van centrados encima: cada lado necesita
        // la mitad del ancho libre, así que la fila mide el lado más ancho dos veces.
        SymmetricSidesLayout(centerWidth: 176 + 2 * 14) {
            playbackInfoCluster
                .fixedSize(horizontal: true, vertical: false)

            optionsBar
                .environment(\.riftCompactPills, compactOptions)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Timeline with Chapter Markers

    private var timeline: some View {
        HStack(spacing: 11) {
            if showsPlaylistSteps, let rift = state as? RiftPlayerState {
                playlistStepButton(
                    systemName: "backward.end.fill",
                    label: NSLocalizedString("Previous Video", comment: ""),
                    isEnabled: rift.previousPlaylistItem != nil,
                    action: rift.playPreviousPlaylistItem
                )
                .padding(.trailing, -6)
            }

            readingClock { time, _ in
                Text(state.formattedTime(isDraggingSlider ? dragSliderValue : time))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 56, alignment: .leading)
                    .foregroundStyle(.primary)
            }

            readingClock { time, _ in timelineTrack(time: time) }

            Text(state.formattedTime(state.duration))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(.secondary)

            if showsPlaylistSteps, let rift = state as? RiftPlayerState {
                playlistStepButton(
                    systemName: "forward.end.fill",
                    label: NSLocalizedString("Next Video", comment: ""),
                    isEnabled: rift.nextPlaylistItem != nil,
                    action: rift.playNextPlaylistItem
                )
                .padding(.leading, -6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func timelineTrack(time: Double) -> some View {
        TimelineTrack(
            currentTime: isDraggingSlider ? dragSliderValue : time,
            duration: max(state.duration, 1),
            thumbnailImage: (state as? RiftPlayerState)?.timelineThumbnail?.image,
            isThumbnailLoading: (state as? RiftPlayerState)?.isTimelineThumbnailLoading ?? false,
            onSeek: {
                isDraggingSlider = true
                dragSliderValue = $0
            },
            onSeekEnd: {
                state.seek(to: $0)
                isDraggingSlider = false
            },
            chapters: (state as? RiftPlayerState)?.chapters.map { TimelineMark(time: $0.start, title: $0.title) } ?? [],
            markers: (state as? RiftPlayerState)?.markers.map { TimelineMark(time: $0.time, title: $0.title) } ?? [],
            onPreviewRequest: { (state as? RiftPlayerState)?.requestTimelineThumbnail(at: $0) },
            onPreviewDismiss: { (state as? RiftPlayerState)?.hideTimelineThumbnailPreview() }
        )
        .accessibilityLabel(NSLocalizedString("Playback position", comment: ""))
    }

    /// Lee tiempo y fps del reloj solo en la vista que los muestra (ver `PlaybackClock`).
    @ViewBuilder
    private func readingClock<Content: View>(
        @ViewBuilder _ content: @escaping (_ time: Double, _ fps: Double) -> Content
    ) -> some View {
        if let clock = (state as? RiftPlayerState)?.clock {
            ClockReader(clock: clock) { content($0.time, $0.renderingFPS) }
        } else {
            content(state.currentTime, state.displayRenderingFPS)
        }
    }

    // MARK: - Playback Info

    /// Solo volumen: los fps viven en la píldora Frame+ y el detalle en
    /// Información técnica (⌘I).
    private var playbackInfoCluster: some View {
        volumeControl
            .frame(minWidth: 134, alignment: .leading)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            GlassIconButton(
                systemName: volumeIcon,
                size: 14,
                action: {
                    state.setVolume(state.volume > 0 ? 0 : 0.68)
                    state.showFeedback(.volume(state.volume))
                },
                accessibilityLabel: state.volume > 0 ? NSLocalizedString("Mute", comment: "") : NSLocalizedString("Unmute", comment: "")
            )

            VolumeTrack(value: state.volume, onChange: state.setVolume)
            .frame(width: 92)
            .accessibilityLabel(NSLocalizedString("Volume", comment: ""))
        }
        .frame(width: 134, alignment: .leading)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 13) {
            GlassIconButton(
                systemName: "gobackward.10",
                size: 15,
                action: {
                    state.seek(by: -10)
                    state.showFeedback(.seek(-10))
                },
                accessibilityLabel: NSLocalizedString("Skip Back 10s", comment: "")
            )

            Button {
                withAnimation(surfaceAnimation) {
                    state.togglePlay()
                }
                state.showFeedback(state.isPlaying ? .play : .pause)
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background {
                        Circle()
                            .fill(.white.opacity(0.15))
                            .overlay { Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.75) }
                    }
                    .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .scaleEffect(reduceMotion ? 1 : (state.isPlaying ? 1 : 0.96))
            .animation(surfaceAnimation, value: state.isPlaying)
            .accessibilityLabel(state.isPlaying ? NSLocalizedString("Pause", comment: "") : NSLocalizedString("Play", comment: ""))

            GlassIconButton(
                systemName: "goforward.10",
                size: 15,
                action: {
                    state.seek(by: 10)
                    state.showFeedback(.seek(10))
                },
                accessibilityLabel: NSLocalizedString("Skip Forward 10s", comment: "")
            )
        }
    }

    /// Anterior / siguiente de la lista, a los lados de los tiempos.
    private func playlistStepButton(systemName: String, label: String, isEnabled: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 0.8 : 0.3))
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: - Options Bar

    private var optionsBar: some View {
        HStack(spacing: 6) {
            interpolationButton
            speedButton
            visualButton

            if state.audioTracks.count > 1 {
                audioTrackButton
            }

            if state.availableTracks.filter({ $0.kind == .subtitle }).count > 0 {
                subtitleButton
            }
        }
    }

    // MARK: - Option Buttons

    private var interpolationButton: some View {
        Button {
            state.setInterpolationMode(
                state.interpolationMode == .disabled ? .motion4x : .disabled
            )
        } label: {
            // Solo la píldora lee el reloj: los fps no redibujan la barra entera.
            readingClock { _, fps in
                glassPill(
                    title: motionTitle(fps: fps),
                    systemName: state.isFramePlusPreparing
                        ? "hourglass"
                        : (state.interpolationMode == .disabled
                            ? "rectangle.on.rectangle"
                            : "rectangle.on.rectangle.fill"),
                    isActive: state.interpolationMode != .disabled,
                    hint: "\(NSLocalizedString("Frame Interpolation", comment: "")) · \(framePlusStateTitle)"
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(NSLocalizedString("Frame Interpolation", comment: "")), \(state.interpolationMode == .disabled ? NSLocalizedString("Interpolation disabled", comment: "") : NSLocalizedString("Interpolation enabled", comment: ""))")
    }

    private var playbackRates: [Float] { [0.5, 1, 1.5, 2] }

    private var speedButton: some View {
        Menu {
            ForEach(playbackRates, id: \.self) { rate in
                Button {
                    withAnimation(surfaceAnimation) { state.playbackRate = rate }
                    state.showFeedback(.rate(rate))
                } label: {
                    let title = rate == 1
                        ? NSLocalizedString("Normal", comment: "")
                        : rate.formatted(.number.precision(.fractionLength(0...1))) + "×"
                    if abs(state.playbackRate - rate) < 0.001 {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            GlassPill(
                title: speedTitle,
                systemName: "gauge.with.dots.needle.33percent",
                isActive: state.playbackRate != 1.0,
                hint: NSLocalizedString("Playback Speed", comment: "")
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(NSLocalizedString("Playback Speed", comment: "")), \(speedTitle)")
    }

    private var visualButton: some View {
        Button {
            showVisualPanel = true
        } label: {
            glassPill(
                title: NSLocalizedString("Visual", comment: ""),
                systemName: "sparkle.magnifyingglass",
                isActive: state.visualEnhancementsEnabled,
                hint: NSLocalizedString("Visual Enhancements", comment: "")
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Open Visual Controls", comment: ""))
        .popover(isPresented: $showVisualPanel, arrowEdge: .bottom) {
            visualControlsPanel
                .background(VideoOverlayGlass(cornerRadius: 16))
        }
    }

    private var visualControlsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(state.visualEnhancementsEnabled ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("Visual Controls", comment: ""))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(activeVisualPreset?.title ?? NSLocalizedString("Custom", comment: "Visual filter"))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button(NSLocalizedString("Reset", comment: "")) {
                    withAnimation(surfaceAnimation) {
                        state.resetVisualEnhancements()
                    }
                }
                .riftGlassButton()
                .controlSize(.small)
                .disabled(!state.visualEnhancementsEnabled)
            }

            visualPresetGrid

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Super Resolution", comment: ""))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Picker(
                    NSLocalizedString("Super Resolution", comment: ""),
                    selection: Binding(
                        get: { state.superResolutionMode != .off },
                        set: { state.setSuperResolutionMode($0 ? .strong : .off) }
                    )
                ) {
                    Text(NSLocalizedString("Off", comment: "")).tag(false)
                    Text(NSLocalizedString("On", comment: "")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(NSLocalizedString("Super Resolution Mode", comment: ""))
            }

            visualAdjustmentRow(
                title: NSLocalizedString("Brightness", comment: ""),
                value: state.visualBrightness,
                range: -0.25...0.25,
                step: 0.01,
                valueText: String(format: "%+.0f%%", state.visualBrightness * 100),
                onChange: state.setVisualBrightness
            )

            visualAdjustmentRow(
                title: NSLocalizedString("Contrast", comment: ""),
                value: state.visualContrast,
                range: 0.5...1.5,
                step: 0.01,
                valueText: String(format: "%.0f%%", state.visualContrast * 100),
                onChange: state.setVisualContrast
            )

            visualAdjustmentRow(
                title: NSLocalizedString("Saturation", comment: ""),
                value: state.visualSaturation,
                range: 0...2,
                step: 0.01,
                valueText: String(format: "%.0f%%", state.visualSaturation * 100),
                onChange: state.setVisualSaturation
            )

            visualAdjustmentRow(
                title: NSLocalizedString("Vibrance", comment: ""),
                value: state.visualVibrance,
                range: 0...1,
                step: 0.01,
                valueText: String(format: "%.0f%%", state.visualVibrance * 100),
                onChange: state.setVisualVibrance
            )

            visualAdjustmentRow(
                title: NSLocalizedString("Temperature", comment: ""),
                value: state.visualTemperature,
                range: -1...1,
                step: 0.01,
                valueText: temperatureText,
                onChange: state.setVisualTemperature
            )
        }
        .padding(16)
        .frame(width: 340)
    }

    private var activeVisualPreset: VisualPreset? {
        VisualPreset.matching(VisualSettings(
            brightness: state.visualBrightness,
            contrast: state.visualContrast,
            saturation: state.visualSaturation,
            temperature: state.visualTemperature,
            vibrance: state.visualVibrance
        ))
    }

    private var temperatureText: String {
        let amount = Int((state.visualTemperature * 100).rounded())
        if amount == 0 { return NSLocalizedString("Neutral", comment: "Color temperature") }
        let format = amount > 0 ? NSLocalizedString("Warm %d", comment: "") : NSLocalizedString("Cool %d", comment: "")
        return String(format: format, abs(amount))
    }

    private var visualPresetGrid: some View {
        let active = activeVisualPreset
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(VisualPreset.allCases, id: \.self) { preset in
                let isSelected = preset == active
                Button {
                    state.applyVisualPreset(preset)
                } label: {
                    Text(preset.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(isSelected ? Color.white : .primary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(preset.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Filters", comment: ""))
    }

    private func visualAdjustmentRow(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)

            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                step: step
            )
            .tint(.accentColor)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
        }
    }

    private var audioTrackButton: some View {
        Menu {
            ForEach(state.audioTracks) { track in
                Button {
                    state.selectAudioTrack(track.id)
                } label: {
                    if track.id == state.selectedAudioTrackIndex {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            GlassPill(
                title: NSLocalizedString("Audio", comment: ""),
                systemName: "music.note.list",
                isActive: state.selectedAudioTrackIndex != (state.audioTracks.first?.id ?? 0),
                hint: NSLocalizedString("Audio Track", comment: "")
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(NSLocalizedString("Audio Track", comment: ""))
    }

    private var subtitleButton: some View {
        let subtitleTracks = state.availableTracks.filter { $0.kind == .subtitle }

        return Menu {
            Button {
                state.selectPipelineTrack(nil)
            } label: {
                Label(NSLocalizedString("None", comment: ""), systemImage: state.selectedSubtitleTrack == nil ? "checkmark" : "captions.bubble")
            }

            Divider()

            ForEach(subtitleTracks) { track in
                Button {
                    state.selectPipelineTrack(track)
                } label: {
                    if state.selectedSubtitleTrack == track {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            GlassPill(
                title: NSLocalizedString("Subs", comment: ""),
                systemName: "captions.bubble",
                isActive: state.selectedSubtitleTrack != nil,
                hint: NSLocalizedString("Subtitles", comment: "")
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(NSLocalizedString("Subtitles", comment: ""))
    }

    // MARK: - Glass Pill

    private func glassPill(title: String, systemName: String, isActive: Bool, hint: String) -> some View {
        GlassPill(title: title, systemName: systemName, isActive: isActive, hint: hint)
    }

    // MARK: - Helpers

    private var accentColor: Color {
        RiftPalette.blue
    }

    private var volumeIcon: String {
        switch state.volume {
        case 0: "speaker.slash.fill"
        case 0..<0.45: "speaker.wave.1.fill"
        default: "speaker.wave.2.fill"
        }
    }

    private var speedTitle: String {
        let value = Double(state.playbackRate)
        return value == 1 ? NSLocalizedString("1x", comment: "") : String(format: NSLocalizedString("%.2gx", comment: ""), value)
    }

    private func motionTitle(fps: Double) -> String {
        if state.isFramePlusPreparing { return "Frame⁺…" }
        // En pausa el reloj conserva el último valor: no lo mostramos como si siguiera.
        guard state.interpolationMode != .disabled, state.isPlaying else { return "Frame⁺" }
        return String(format: NSLocalizedString("Frame+ · %.0f fps", comment: "Frame+ pill with live frame rate"), fps)
    }

    private var framePlusStateTitle: String {
        if state.isFramePlusPreparing { return NSLocalizedString("Preparing HQ", comment: "") }
        if state.isFramePlusPreRendered {
            let target = (state as? RiftPlayerState)?.targetRenderingFPS ?? 60
            return String(format: NSLocalizedString("Target %.0f fps", comment: "Frame+ target frame rate"), target)
        }
        if state.interpolationMode == .disabled { return NSLocalizedString("Disabled", comment: "") }
        return state.isArtificialInterpolationActive ? NSLocalizedString("Interpolating", comment: "") : NSLocalizedString("Waiting", comment: "")
    }

    private var surfaceAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.24)
    }
}

private struct CompactPillsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var riftCompactPills: Bool {
        get { self[CompactPillsKey.self] }
        set { self[CompactPillsKey.self] = newValue }
    }
}

private struct GlassPill: View {
    let title: String
    let systemName: String
    let isActive: Bool
    let hint: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.riftCompactPills) private var compact
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .modifier(BusySymbolEffect(isActive: systemName == "hourglass" && !reduceMotion))
                .frame(width: 13)

            if !compact {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(isActive ? .white : .white.opacity(isHovered ? 0.84 : 0.60))
        .frame(height: 32)
        .padding(.horizontal, 11)
        .background {
            ZStack {
                Capsule()
                    .fill(.white.opacity(isHovered ? 0.040 : 0.006))

                if isActive {
                    Capsule()
                        .fill(RiftPalette.luminousGradient.opacity(0.20))
                }

                Capsule().strokeBorder(
                    isActive ? accentColor.opacity(0.48) : .white.opacity(isHovered ? 0.15 : 0.09),
                    lineWidth: 0.5
                )
            }
        }
        .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.025 : 1))
        .contentShape(Capsule())
        .help(hint)
        .onHover { hovering in
            withAnimation(hoverAnimation) {
                isHovered = hovering
            }
        }
    }

    private var accentColor: Color {
        RiftPalette.blue
    }

    private var hoverAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.14)
    }
}

// MARK: - Volume Track

struct VolumeTrack: View {
    let value: Double
    let onChange: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDragging = false
    @State private var isHovering = false

    private var trackHeight: CGFloat {
        (isHovering || isDragging) ? 6 : 3
    }

    private var thumbSize: CGFloat {
        (isHovering || isDragging) ? 12 : 8
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.30))
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    }

                Capsule()
                    .fill(RiftPalette.luminousGradient)
                    .frame(width: geo.size.width * value, height: trackHeight)
                    .shadow(color: RiftPalette.blue.opacity(0.45), radius: isDragging ? 5 : 3)

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                    .position(x: geo.size.width * value, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                isDragging = true
                                onChange(normalizedValue(at: gesture.location.x, width: geo.size.width))
                            }
                            .onEnded { gesture in
                                isDragging = false
                                onChange(normalizedValue(at: gesture.location.x, width: geo.size.width))
                            }
                    )
            }
        }
        .frame(height: 30)
        .onHover { isHovering = $0 }
        .animation(trackAnimation, value: isHovering)
        .animation(trackAnimation, value: isDragging)
    }

    private func normalizedValue(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return value }
        return Double(min(max(x, 0), width) / width)
    }

    private var trackAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
    }
}

// MARK: - Timeline Track

/// Capítulo o marcador dibujado sobre la línea de tiempo.
struct TimelineMark: Equatable {
    let time: Double
    let title: String
}

struct TimelineTrack: View {
    let currentTime: Double
    let duration: Double
    let thumbnailImage: CGImage?
    let isThumbnailLoading: Bool
    let onSeek: (Double) -> Void
    let onSeekEnd: (Double) -> Void
    var chapters: [TimelineMark] = []
    var markers: [TimelineMark] = []
    let onPreviewRequest: (Double) -> Void
    let onPreviewDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragProgress: Double = 0
    @State private var previewProgress: Double = 0

    private var progress: Double {
        min(isDragging ? dragProgress : (currentTime / max(duration, 1)), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.30))
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    }

                Capsule()
                    .fill(RiftPalette.luminousGradient)
                    .frame(width: geo.size.width * progress, height: trackHeight)
                    .shadow(color: accentColor.opacity(0.45), radius: isDragging ? 5 : 3, x: 0, y: 0)

                timelineMarks(in: geo.size)

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                    .position(x: geo.size.width * progress, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity)
                    .frame(height: geo.size.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            isHovering = true
                            updatePreview(at: location.x, width: geo.size.width)
                        case .ended:
                            isHovering = false
                            if !isDragging {
                                onPreviewDismiss()
                            }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let w = max(0, min(CGFloat(value.location.x), geo.size.width))
                                dragProgress = Double(w / geo.size.width)
                                updatePreview(at: w, width: geo.size.width)
                                onSeek(dragProgress * duration)
                            }
                            .onEnded { value in
                                isDragging = false
                                let w = max(0, min(CGFloat(value.location.x), geo.size.width))
                                updatePreview(at: w, width: geo.size.width)
                                onSeekEnd((Double(w) / Double(geo.size.width)) * duration)
                                if !isHovering {
                                    onPreviewDismiss()
                                }
                            }
                    )

                if (isHovering || isDragging) && (thumbnailImage != nil || isThumbnailLoading) {
                    timelinePreview
                        .position(
                            x: min(max(geo.size.width * previewProgress, 78), geo.size.width - 78),
                            y: previewChapter == nil ? -58 : -73
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .animation(trackAnimation, value: isHovering)
        .animation(trackAnimation, value: isDragging)
        .accessibilityLabel(NSLocalizedString("Timeline", comment: ""))
        .accessibilityValue(String(format: NSLocalizedString("%@ of %@", comment: ""), PlaybackTimeFormat.string(currentTime), PlaybackTimeFormat.string(duration)))
    }

    private func formatTime(_ seconds: Double) -> String {
        PlaybackTimeFormat.string(seconds)
    }

    private var timelinePreview: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnailImage {
                    Image(decorative: thumbnailImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.black.opacity(0.55)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: 148, height: 83)
            .clipped()

            Text(formatTime(previewProgress * duration))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))

            if let chapter = previewChapter {
                // Hasta dos líneas: los títulos de capítulo suelen ser largos.
                Text(chapter.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 148)
            }
        }
        .padding(4)
        .background {
            VideoOverlayGlass(cornerRadius: 9)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    /// Cortes de capítulo (muesca oscura que atraviesa la barra) y marcadores
    /// del usuario (punto sobre la barra).
    @ViewBuilder
    private func timelineMarks(in size: CGSize) -> some View {
        let visibleChapters = chapters.filter { $0.time > 0.5 && $0.time < duration - 0.5 }
        ForEach(visibleChapters.indices, id: \.self) { (index: Int) in
            Rectangle()
                .fill(.black.opacity(0.6))
                .frame(width: 2, height: trackHeight + 2)
                .position(x: size.width * visibleChapters[index].time / duration, y: size.height / 2)
                .allowsHitTesting(false)
        }
        ForEach(markers.indices, id: \.self) { (index: Int) in
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 4, height: 4)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .position(x: size.width * min(max(markers[index].time / duration, 0), 1),
                          y: size.height / 2 - trackHeight / 2 - 5)
                .allowsHitTesting(false)
        }
    }

    /// Capítulo bajo el puntero: el último que empieza antes de ese tiempo.
    private var previewChapter: TimelineMark? {
        let time = previewProgress * duration
        return chapters.last { $0.time <= time + 0.01 }.flatMap { $0.title.isEmpty ? nil : $0 }
    }

    private func updatePreview(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        previewProgress = min(max(Double(x / width), 0), 1)
        onPreviewRequest(previewProgress * duration)
    }

    private var accentColor: Color {
        RiftPalette.blue
    }

    private var trackHeight: CGFloat {
        (isHovering || isDragging) ? 6 : 3
    }

    private var thumbSize: CGFloat {
        (isHovering || isDragging) ? 12 : 8
    }

    private var trackAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
    }
}

// MARK: - Busy symbol

/// Gira el ícono solo mientras dura la preparación de Frame+ (unos segundos).
private struct BusySymbolEffect: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.rotate, options: .speed(0.6), isActive: isActive)
        } else {
            content.symbolEffect(.pulse, isActive: isActive)
        }
    }
}

// MARK: - GlassIconButton

struct GlassIconButton: View {
    var systemName: String
    var size: CGFloat = 15
    var action: () -> Void
    var accessibilityLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPressed = false
    @State private var isHovered = false
    @State private var tapCount = 0

    var body: some View {
        Button(action: {
            tapCount += 1
            withAnimation(pressAnimation) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(pressAnimation) {
                    isPressed = false
                }
            }
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : tapCount)
                .foregroundStyle(.white.opacity(isHovered ? 0.96 : 0.70))
                .frame(width: 38, height: 38)
                .background {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.025))

                        if isHovered {
                            Circle()
                                .fill(RiftPalette.luminousGradient.opacity(0.18))
                        }
                    }
                }
                .overlay {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.08), lineWidth: 0.5)

                        if isHovered {
                            Circle().strokeBorder(RiftPalette.cyan.opacity(0.48), lineWidth: 0.5)
                        }
                    }
                }
                .shadow(color: isHovered ? RiftPalette.blue.opacity(0.20) : .clear, radius: 8)
                .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.90 : (isHovered ? 1.04 : 1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? labelFromSystemName)
        .onHover { hovering in
            withAnimation(hoverAnimation) {
                isHovered = hovering
            }
        }
    }

    private var labelFromSystemName: String {
        switch systemName {
        case "gobackward.10": NSLocalizedString("Skip Back 10s", comment: "")
        case "goforward.10": NSLocalizedString("Skip Forward 10s", comment: "")
        case "speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill": NSLocalizedString("Mute", comment: "")
        default: systemName
        }
    }

    private var hoverAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.15)
    }

    private var pressAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.25, 1, 0.5, 1, duration: 0.12)
    }
}

/// También lo usa el panel de Información técnica.
struct ClockReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    let content: (PlaybackClock) -> Content

    var body: some View { content(clock) }
}
