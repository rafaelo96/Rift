import SwiftUI
import Contracts
import Decode

struct PlayerControlsView<PlayerStateType: PlayerStateProviding>: View {
    @ObservedObject var state: PlayerStateType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDraggingSlider = false
    @State private var dragSliderValue: Double = 0
    @State private var showAudioMenu = false
    @State private var showSubsMenu = false

    var body: some View {
        LiquidGlassPanel(cornerRadius: 28) {
            VStack(spacing: 8) {
                timeline
                    .padding(.horizontal, 2)

                HStack(spacing: 10) {
                    playbackInfoCluster
                        .frame(maxWidth: .infinity, alignment: .leading)

                    transportControls
                        .frame(width: 168)

                    optionsBar
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 880)
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
        HStack(spacing: 10) {
            Text(state.formattedTime(isDraggingSlider ? dragSliderValue : state.currentTime))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 68, alignment: .leading)
                .foregroundStyle(.white.opacity(0.88))

            TimelineTrack(
                currentTime: isDraggingSlider ? dragSliderValue : state.currentTime,
                duration: max(state.duration, 1),
                thumbnailImage: (state as? RiftPlayerState)?.timelineThumbnail?.image,
                isThumbnailLoading: (state as? RiftPlayerState)?.isTimelineThumbnailLoading ?? false,
                onSeek: { value in
                    withAnimation(surfaceAnimation) {
                        isDraggingSlider = true
                        dragSliderValue = value
                    }
                },
                onSeekEnd: { value in
                    state.seek(to: value)
                    isDraggingSlider = false
                },
                onPreviewRequest: { time in
                    (state as? RiftPlayerState)?.requestTimelineThumbnail(at: time)
                },
                onPreviewDismiss: {
                    (state as? RiftPlayerState)?.hideTimelineThumbnailPreview()
                }
            )

            Text(state.formattedTime(state.duration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 68, alignment: .trailing)
                .foregroundStyle(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Playback Info

    private var playbackInfoCluster: some View {
        HStack(spacing: 9) {
            volumeControl

            optionDivider

            fpsReadout
        }
        .frame(minWidth: 184, alignment: .leading)
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            GlassIconButton(
                systemName: volumeIcon,
                size: 14,
                action: { state.setVolume(state.volume > 0 ? 0 : 0.68) },
                accessibilityLabel: state.volume > 0 ? NSLocalizedString("Mute", comment: "") : NSLocalizedString("Unmute", comment: "")
            )

            VolumeTrack(
                value: state.volume,
                onChange: { state.setVolume($0) }
            )
            .frame(width: 72)
            .accessibilityLabel(NSLocalizedString("Volume", comment: ""))
        }
        .frame(width: 96, alignment: .leading)
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
                Text(String(format: NSLocalizedString("%.0f FPS", comment: ""), state.displayRenderingFPS))
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
        HStack(spacing: 14) {
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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background {
                        Circle()
                            .fill(RiftPalette.luminousGradient)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.72), lineWidth: 0.5)
                                    .padding(1)
                            }
                    }
                    .shadow(color: RiftPalette.cyan.opacity(0.24), radius: 10, x: 0, y: -2)
                    .shadow(color: RiftPalette.blue.opacity(0.42), radius: 18, x: 0, y: 8)
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
        HStack(spacing: 5) {
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
            withAnimation(surfaceAnimation) {
                state.toggleVisualEnhancements()
            }
        } label: {
            glassPill(
                title: NSLocalizedString("Visual", comment: ""),
                systemName: "sparkle.magnifyingglass",
                isActive: state.visualEnhancementsEnabled,
                hint: NSLocalizedString("Visual Enhancements", comment: "")
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(NSLocalizedString("Visual Enhancements", comment: "")), \(state.visualEnhancementsEnabled ? NSLocalizedString("Visual on", comment: "") : NSLocalizedString("Visual off", comment: ""))")
    }

    private var audioTrackButton: some View {
        Button {
            showAudioMenu = true
        } label: {
            glassPill(
                title: NSLocalizedString("Audio", comment: ""),
                systemName: "music.note.list",
                isActive: state.selectedAudioTrackIndex != (state.audioTracks.first?.id ?? 0),
                hint: NSLocalizedString("Audio Track", comment: "")
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Audio Track", comment: ""))
        .popover(isPresented: $showAudioMenu, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(state.audioTracks) { track in
                    Button {
                        showAudioMenu = false
                        withAnimation(surfaceAnimation) {
                            state.selectAudioTrack(track.id)
                        }
                    } label: {
                        optionMenuRow(title: track.label, selected: track.id == state.selectedAudioTrackIndex)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 184)
            .background(GlassBackground(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RiftPalette.cyan.opacity(0.22), lineWidth: 0.5)
            }
        }
    }

    private var subtitleButton: some View {
        let subtitleTracks = state.availableTracks.filter { $0.kind == .subtitle }

        return Button {
            showSubsMenu = true
        } label: {
            glassPill(
                title: NSLocalizedString("Subs", comment: ""),
                systemName: "captions.bubble",
                isActive: state.selectedSubtitleTrack != nil,
                hint: NSLocalizedString("Subtitles", comment: "")
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Subtitles", comment: ""))
        .popover(isPresented: $showSubsMenu, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                Button {
                    showSubsMenu = false
                    withAnimation(surfaceAnimation) {
                        state.selectPipelineTrack(nil)
                    }
                } label: {
                    optionMenuRow(title: "None", selected: state.selectedSubtitleTrack == nil)
                }
                .buttonStyle(.plain)

                ForEach(subtitleTracks) { track in
                    Button {
                        showSubsMenu = false
                        withAnimation(surfaceAnimation) {
                            state.selectPipelineTrack(track)
                        }
                    } label: {
                        optionMenuRow(title: track.label, selected: state.selectedSubtitleTrack == track)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 184)
            .background(GlassBackground(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RiftPalette.cyan.opacity(0.22), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Glass Pill

    private func glassPill(title: String, systemName: String, isActive: Bool, hint: String) -> some View {
        GlassPill(
            title: title,
            systemName: systemName,
            isActive: isActive,
            hint: hint
        )
    }

    // MARK: - Helpers

    private func optionMenuRow(title: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? RiftPalette.cyan : .white.opacity(0.28))

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(selected ? 0.98 : 0.72))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(RiftPalette.luminousGradient.opacity(0.18))
            }
        }
    }

    private var optionDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 0.5, height: 22)
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
            return state.displayRenderingFPS >= 52
                ? NSLocalizedString("60fps ready", comment: "")
                : NSLocalizedString("48fps ready", comment: "")
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
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 12)

            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(isActive ? .white : .white.opacity(isHovered ? 0.84 : 0.60))
        .frame(height: 28)
        .padding(.horizontal, 10)
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
            GlassBackground(cornerRadius: 9, effectOpacity: 0.34)
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
                .frame(width: 34, height: 34)
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
