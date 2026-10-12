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
                    HStack(spacing: 14) {
                        playbackInfoCluster
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 190)

                        optionsBar
                            .fixedSize(horizontal: true, vertical: false)
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

    // MARK: - Timeline with Chapter Markers

    private var timeline: some View {
        HStack(spacing: 11) {
            Text(state.formattedTime(isDraggingSlider ? dragSliderValue : state.currentTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 56, alignment: .leading)
                .foregroundStyle(.primary)

            TimelineTrack(
                currentTime: isDraggingSlider ? dragSliderValue : state.currentTime,
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
                onPreviewRequest: { (state as? RiftPlayerState)?.requestTimelineThumbnail(at: $0) },
                onPreviewDismiss: { (state as? RiftPlayerState)?.hideTimelineThumbnailPreview() }
            )
            .accessibilityLabel(NSLocalizedString("Playback position", comment: ""))

            Text(state.formattedTime(state.duration))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Playback Info

    private var playbackInfoCluster: some View {
        HStack(spacing: 11) {
            volumeControl

            optionDivider

            fpsReadout
        }
        .frame(minWidth: 184, alignment: .leading)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            GlassIconButton(
                systemName: volumeIcon,
                size: 14,
                action: { state.setVolume(state.volume > 0 ? 0 : 0.68) },
                accessibilityLabel: state.volume > 0 ? NSLocalizedString("Mute", comment: "") : NSLocalizedString("Unmute", comment: "")
            )

            VolumeTrack(value: state.volume, onChange: state.setVolume)
            .frame(width: 92)
            .accessibilityLabel(NSLocalizedString("Volume", comment: ""))
        }
        .frame(width: 134, alignment: .leading)
    }

    private var fpsReadout: some View {
        HStack(spacing: 6) {
            Image(systemName: state.fpsMode.isActive
                ? "gauge.open.with.lines.needle.33percent"
                : "display")
                .font(.system(size: 11, weight: .semibold, design: .rounded))

            Circle()
                .fill(state.fpsMode.isActive ? accentColor : .white.opacity(0.28))
                .frame(width: 4, height: 4)
                .shadow(color: state.fpsMode.isActive ? accentColor.opacity(0.55) : .clear, radius: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.0f fps ↗", state.displayRenderingFPS))
                    .help("Frames entregados al sistema por segundo; no mide la presentación física de la pantalla.")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)

                Text(framePlusStateTitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(state.fpsMode.isActive ? accentColor : .white.opacity(0.78))
        .frame(width: 88, alignment: .leading)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 13) {
            GlassIconButton(
                systemName: "gobackward.10",
                size: 15,
                action: { state.seek(by: -10) },
                accessibilityLabel: NSLocalizedString("Skip Back 10s", comment: "")
            )

            Button {
                withAnimation(surfaceAnimation) {
                    state.togglePlay()
                }
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
            .keyboardShortcut(.space, modifiers: [])
            .scaleEffect(reduceMotion ? 1 : (state.isPlaying ? 1 : 0.96))
            .animation(surfaceAnimation, value: state.isPlaying)
            .accessibilityLabel(state.isPlaying ? NSLocalizedString("Pause", comment: "") : NSLocalizedString("Play", comment: ""))

            GlassIconButton(
                systemName: "goforward.10",
                size: 15,
                action: { state.seek(by: 10) },
                accessibilityLabel: NSLocalizedString("Skip Forward 10s", comment: "")
            )
        }
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
            glassPill(
                title: motionTitle,
                systemName: state.isFramePlusPreparing
                    ? "hourglass"
                    : (state.interpolationMode == .disabled
                        ? "rectangle.on.rectangle"
                        : "rectangle.on.rectangle.fill"),
                isActive: state.interpolationMode != .disabled,
                hint: NSLocalizedString("Frame Interpolation", comment: "")
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(NSLocalizedString("Frame Interpolation", comment: "")), \(state.interpolationMode == .disabled ? NSLocalizedString("Interpolation disabled", comment: "") : NSLocalizedString("Interpolation enabled", comment: ""))")
    }

    private var speedButton: some View {
        Button {
            withAnimation(surfaceAnimation) {
                state.cyclePlaybackRate()
            }
        } label: {
            glassPill(
                title: speedTitle,
                systemName: "gauge.with.dots.needle.33percent",
                isActive: state.playbackRate != 1.0,
                hint: NSLocalizedString("Playback Speed", comment: "")
            )
        }
        .buttonStyle(.plain)
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
                    Text(state.visualEnhancementsEnabled
                         ? NSLocalizedString("Custom image adjustments", comment: "")
                         : NSLocalizedString("Neutral image", comment: ""))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
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
        }
        .padding(16)
        .frame(width: 340)
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
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
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

    private var optionDivider: some View {
        Divider().frame(height: 22)
    }

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

    private var motionTitle: String {
        if state.isFramePlusPreparing { return "Frame⁺..." }
        return "Frame⁺"
    }

    private var framePlusStateTitle: String {
        if state.isFramePlusPreparing { return NSLocalizedString("Preparing HQ", comment: "") }
        if state.isFramePlusPreRendered {
            let target = (state as? RiftPlayerState)?.targetRenderingFPS ?? 60
            return String(format: "Objetivo %.0f fps", target)
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

private struct GlassPill: View {
    let title: String
    let systemName: String
    let isActive: Bool
    let hint: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 13)

            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
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

struct TimelineTrack: View {
    let currentTime: Double
    let duration: Double
    let thumbnailImage: CGImage?
    let isThumbnailLoading: Bool
    let onSeek: (Double) -> Void
    let onSeekEnd: (Double) -> Void
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
                            y: -58
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
        .accessibilityValue(String(format: NSLocalizedString("%d:%02d of %d:%02d", comment: ""), Int(currentTime / 60), Int(currentTime.truncatingRemainder(dividingBy: 60)), Int(duration / 60), Int(duration.truncatingRemainder(dividingBy: 60))))
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let m = s / 60
        let sec = s % 60
        return "\(m):\(String(format: "%02d", sec))"
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(4)
        .background {
            GlassBackground(cornerRadius: 9, effectOpacity: 0.24)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
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

// MARK: - GlassIconButton

struct GlassIconButton: View {
    var systemName: String
    var size: CGFloat = 15
    var action: () -> Void
    var accessibilityLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        Button(action: {
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
