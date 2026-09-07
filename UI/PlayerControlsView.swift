import SwiftUI
import Contracts

struct PlayerControlsView<PlayerStateType: PlayerStateProviding>: View {
    @ObservedObject var state: PlayerStateType

    @State private var isDraggingSlider = false
    @State private var dragSliderValue: Double = 0
    @State private var showAudioMenu = false
    @State private var showSubsMenu = false

    var body: some View {
        LiquidGlassPanel(cornerRadius: 18, blendsWithWindow: true) {
            VStack(spacing: 12) {
                HStack {
                    Spacer(minLength: 24)
                    timeline
                    Spacer(minLength: 24)
                }

                HStack(spacing: 16) {
                    playbackInfoCluster
                        .frame(maxWidth: .infinity, alignment: .leading)

                    transportControls
                        .frame(width: 154)

                    optionsBar
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: 980)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.isPlaying)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.playbackRate)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.fpsMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.interpolationMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.audioTracks.count)
    }

    // MARK: - Timeline with Chapter Markers

    private var timeline: some View {
        HStack(spacing: 10) {
            Text(state.formattedTime(isDraggingSlider ? dragSliderValue : state.currentTime))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(width: 68, alignment: .leading)
                .foregroundStyle(.white.opacity(0.92))

            TimelineTrack(
                currentTime: isDraggingSlider ? dragSliderValue : state.currentTime,
                duration: max(state.duration, 1),
                onSeek: { value in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        isDraggingSlider = true
                        dragSliderValue = value
                    }
                },
                onSeekEnd: { value in
                    state.seek(to: value)
                    isDraggingSlider = false
                }
            )

            Text(state.formattedTime(state.duration))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(width: 68, alignment: .trailing)
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: 680)
    }

    // MARK: - Playback Info

    private var playbackInfoCluster: some View {
        HStack(spacing: 12) {
            volumeControl

            optionDivider

            fpsReadout
        }
        .frame(minWidth: 210, alignment: .leading)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            GlassIconButton(
                systemName: volumeIcon,
                size: 14,
                action: { state.setVolume(state.volume > 0 ? 0 : 0.68) },
                accessibilityLabel: state.volume > 0 ? NSLocalizedString("Mute", comment: "") : NSLocalizedString("Unmute", comment: "")
            )

            Slider(
                value: Binding(
                    get: { state.volume },
                    set: { state.setVolume($0) }
                ),
                in: 0...1
            )
            .tint(accentColor)
            .frame(width: 82)
            .accessibilityLabel(NSLocalizedString("Volume", comment: ""))
        }
        .frame(width: 112, alignment: .leading)
    }

    private var fpsReadout: some View {
        HStack(spacing: 6) {
            Image(systemName: state.fpsMode.isActive
                ? "gauge.open.with.lines.needle.33percent"
                : "display")
                .font(.system(size: 11, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: NSLocalizedString("%.0f FPS", comment: ""), state.displayRenderingFPS))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Text(framePlusStateTitle)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(state.fpsMode.isActive ? accentColor : .white.opacity(0.78))
        .frame(width: 76, alignment: .leading)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 18) {
            GlassIconButton(
                systemName: "gobackward.10",
                size: 15,
                action: { state.seek(by: -10) },
                accessibilityLabel: NSLocalizedString("Skip Back 10s", comment: "")
            )

            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) {
                    state.togglePlay()
                }
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [.white.opacity(0.22), .white.opacity(0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.5
                                    )
                            }
                    }
                    .shadow(color: Color(red: 0.36, green: 0.66, blue: 1.0).opacity(0.18), radius: 14, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .scaleEffect(state.isPlaying ? 1 : 0.96)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: state.isPlaying)
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
        HStack(spacing: 4) {
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
            withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
                guard state.interpolationMode == .disabled else {
                    state.setInterpolationMode(.disabled)
                    return
                }
                state.setInterpolationMode(.motion2x)
            }
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
        .accessibilityLabel("\(NSLocalizedString("Frame Interpolation", comment: "")), \(state.interpolationMode == .disabled ? NSLocalizedString("Interpolation disabled", comment: "") : NSLocalizedString("Interpolation active", comment: ""))")
    }

    private var speedButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
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
            withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
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
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
                            state.selectAudioTrack(track.id)
                        }
                    } label: {
                        optionMenuRow(title: track.label, selected: track.id == state.selectedAudioTrackIndex)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
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
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
                        state.selectPipelineTrack(nil)
                    }
                } label: {
                    optionMenuRow(title: "None", selected: state.selectedSubtitleTrack == nil)
                }
                .buttonStyle(.plain)

                ForEach(subtitleTracks) { track in
                    Button {
                        showSubsMenu = false
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
                            state.selectPipelineTrack(track)
                        }
                    } label: {
                        optionMenuRow(title: track.label, selected: state.selectedSubtitleTrack == track)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
    }

    // MARK: - Glass Pill

    private func glassPill(title: String, systemName: String, isActive: Bool, hint: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 12)

            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(isActive ? .white : .white.opacity(0.6))
        .frame(height: 24)
        .padding(.horizontal, 10)
        .background {
            ZStack {
                Capsule()
                    .fill(isActive
                        ? accentColor.opacity(0.2)
                        : .white.opacity(0.04))
                Capsule()
                    .strokeBorder(
                        isActive
                            ? LinearGradient(colors: [accentColor.opacity(0.4), accentColor.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.5
                    )
            }
        }
        .contentShape(Capsule())
        .help(hint)
    }

    // MARK: - Helpers

    private func optionMenuRow(title: String, selected: Bool) -> some View {
        Group {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var optionDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 0.5, height: 22)
    }

    private var accentColor: Color {
        Color(red: 0.36, green: 0.66, blue: 1.0)
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
        state.isFramePlusPreparing ? "Frame⁺..." : "Frame⁺"
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
}

// MARK: - Timeline Track

struct TimelineTrack: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onSeekEnd: (Double) -> Void

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var progress: Double {
        min(isDragging ? dragProgress : (currentTime / max(duration, 1)), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(.white.opacity(0.08))
                    .frame(height: 4)

                // Filled track
                Capsule()
                    .fill(accentColor)
                    .frame(width: geo.size.width * progress, height: 6)
                    .shadow(color: accentColor.opacity(0.3), radius: 4, x: 0, y: 0)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                    .position(x: geo.size.width * progress, y: 14)
                    .allowsHitTesting(false)

                // Hit area
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let w = max(0, min(CGFloat(value.location.x), geo.size.width))
                                dragProgress = Double(w / geo.size.width)
                                onSeek(dragProgress * duration)
                            }
                            .onEnded { value in
                                isDragging = false
                                let w = max(0, min(CGFloat(value.location.x), geo.size.width))
                                onSeekEnd((Double(w) / Double(geo.size.width)) * duration)
                            }
                    )

                // Time tooltip when dragging
                if isDragging {
                    let dragTime = dragProgress * duration
                    Text(formatTime(dragTime))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(.black.opacity(0.7))
                        }
                        .position(x: min(max(geo.size.width * progress, 30), geo.size.width - 30), y: -14)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .accessibilityLabel(NSLocalizedString("Timeline", comment: ""))
        .accessibilityValue(String(format: NSLocalizedString("%d:%02d of %d:%02d", comment: ""), Int(currentTime / 60), Int(currentTime.truncatingRemainder(dividingBy: 60)), Int(duration / 60), Int(duration.truncatingRemainder(dividingBy: 60))))
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let m = s / 60
        let sec = s % 60
        return "\(m):\(String(format: "%02d", sec))"
    }

    private var accentColor: Color {
        Color(red: 0.36, green: 0.66, blue: 1.0)
    }
}

// MARK: - GlassIconButton

struct GlassIconButton: View {
    var systemName: String
    var size: CGFloat = 15
    var action: () -> Void
    var accessibilityLabel: String?

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) {
                    isPressed = false
                }
            }
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.92 : 0.70))
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(.white.opacity(isHovered ? 0.08 : 0.03))
                }
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(isHovered ? 0.14 : 0.06), lineWidth: 0.5)
                }
                .scaleEffect(isPressed ? 0.88 : (isHovered ? 1.06 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? labelFromSystemName)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
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
}