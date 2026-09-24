import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Contracts
import AVFoundation

private struct PlayerStateFocusedKey: FocusedValueKey {
    typealias Value = RiftPlayerState
}
extension FocusedValues {
    var playerState: RiftPlayerState? {
        get { self[PlayerStateFocusedKey.self] }
        set { self[PlayerStateFocusedKey.self] = newValue }
    }
}

// MARK: - Rift brand mark

private struct RiftBrandMark: View {
    var size: CGFloat = 96

    var body: some View {
        if let url = Bundle.module.url(forResource: "Rift-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    var player: AVPlayer?
    var videoGravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = videoGravity
        layer.needsDisplayOnBoundsChange = true
        view.layer = layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer as? AVPlayerLayer {
            if layer.player !== player { layer.player = player }
            layer.videoGravity = videoGravity
        }
    }
}

private class HDRDisplayNSView: NSView {
    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            displayLayer?.videoGravity = videoGravity
        }
    }

    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            if let old = oldValue, old.superlayer === self.layer {
                old.removeFromSuperlayer()
            }
            if let l = displayLayer {
                self.layer?.addSublayer(l)
                l.videoGravity = videoGravity
                l.needsDisplayOnBoundsChange = true
                l.isOpaque = true
                needsLayout = true
            }
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true; layer = CALayer() }
    override func layout() {
        super.layout()
        displayLayer?.frame = bounds
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let l = displayLayer {
            l.frame = bounds
        }
    }
}

private struct HDRDisplayView: NSViewRepresentable {
    var displayLayer: AVSampleBufferDisplayLayer?
    var videoGravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> NSView {
        let view = HDRDisplayNSView(frame: .zero)
        view.videoGravity = videoGravity
        view.displayLayer = displayLayer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? HDRDisplayNSView else { return }
        view.videoGravity = videoGravity
        view.displayLayer = displayLayer
        view.needsLayout = true
    }
}

private enum VideoPresentationMode: CaseIterable, Identifiable {
    case fit
    case fill

    var id: Self { self }

    var title: String {
        switch self {
        case .fit: NSLocalizedString("Fit", comment: "Video presentation mode")
        case .fill: NSLocalizedString("Fill", comment: "Video presentation mode")
        }
    }

    var icon: String {
        switch self {
        case .fit: "rectangle.inset.filled"
        case .fill: "rectangle.fill"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        }
    }
}

private struct TopChromeGlyph: View {
    let systemName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isHovered ? 0.98 : 0.76))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(.white.opacity(isHovered ? 0.16 : 0.001))
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(isHovered ? 0.24 : 0.001), lineWidth: 0.5)
            }
            .scaleEffect(reduceMotion || !isHovered ? 1 : 1.04)
            .animation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct TopChromeButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TopChromeGlyph(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

// MARK: - Ambient particle for cinematic atmosphere

private struct AmbientParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var speed: CGFloat
    var opacity: Double
    var delay: Double
}

struct ContentView<PlayerStateType: PlayerStateProviding>: View {
    @ObservedObject var state: PlayerStateType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTargeted = false

    @State private var keyboardEventMonitor: Any? = nil
    @State private var mouseMonitor: Any? = nil
    @State private var windowSize: CGSize = .zero
    @State private var interactiveReady = false

    @State private var particles: [AmbientParticle] = []
    @State private var promptPulse: CGFloat = 0

    @State private var controlsPosition: CGPoint = .zero
    @State private var controlsDrag: CGSize = .zero
    @State private var controlsSize: CGSize = .zero
    @State private var isPositionInitialized = false
    @State private var isDraggingControls = false
    @State private var presentationMode: VideoPresentationMode = .fit
    @State private var showTechnicalInfo = false
    @State private var showPlaybackOptions = false

    init(state: PlayerStateType) {
        self.state = state
    }

    var body: some View {
        ZStack {
            appBackdrop

            if state.hasVideo {
                videoContentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        if interactiveReady {
                            topPlayerControls
                                .zIndex(1)
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                .opacity(state.areControlsVisible ? 1.0 : 0.0)
                                .scaleEffect(reduceMotion ? 1 : (state.areControlsVisible ? 1 : 0.985))
                                .offset(y: reduceMotion || state.areControlsVisible ? 0 : 10)
                                .blur(radius: reduceMotion || state.areControlsVisible ? 0 : 3)
                                .allowsHitTesting(state.areControlsVisible)
                                .animation(controlVisibilityAnimation, value: state.areControlsVisible)
                                .onHover { isHovering in
                                    if isHovering {
                                        state.stopHideTimer()
                                    } else {
                                        state.startHideTimer()
                                    }
                                }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.01)))
            }

            if state.hasVideo, let subtitleText = state.currentSubtitleText, !subtitleText.isEmpty {
                subtitleOverlay(subtitleText)
                    .transition(.opacity)
            }

            if !state.hasVideo, interactiveReady {
                openVideoPrompt
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if interactiveReady, state.hasVideo {
                GeometryReader { geometry in
                    ZStack {
                        PlayerControlsView(state: state)
                    }
                    .opacity(state.areControlsVisible ? 1.0 : 0.0)
                    .scaleEffect(reduceMotion ? 1 : (state.areControlsVisible ? 1 : 0.985))
                    .offset(y: reduceMotion || state.areControlsVisible ? 0 : 10)
                    .blur(radius: reduceMotion || state.areControlsVisible ? 0 : 3)
                    .allowsHitTesting(state.areControlsVisible)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onAppear { controlsSize = proxy.size }
                        }
                    }
                    .position(
                        x: controlsPosition.x + controlsDrag.width,
                        y: controlsPosition.y + controlsDrag.height
                    )
                    .scaleEffect(isDraggingControls ? 0.98 : 1)
                    .animation(controlVisibilityAnimation, value: state.areControlsVisible)
                    .animation(controlDragAnimation, value: isDraggingControls)
                    .onAppear {
                        guard !isPositionInitialized else { return }
                        controlsPosition = CGPoint(x: geometry.size.width / 2, y: geometry.size.height - 82)
                        windowSize = geometry.size
                        isPositionInitialized = true
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        guard windowSize.width > 0, windowSize.height > 0 else { return }
                        let ratioX = controlsPosition.x / windowSize.width
                        let ratioY = controlsPosition.y / windowSize.height
                        controlsPosition = CGPoint(x: ratioX * newSize.width, y: ratioY * newSize.height)
                        windowSize = newSize
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                controlsDrag = value.translation
                                isDraggingControls = true
                            }
                            .onEnded { value in
                                let margin: CGFloat = 8
                                let halfW = controlsSize.width / 2
                                let halfH = controlsSize.height / 2
                                let w = geometry.size.width
                                let h = geometry.size.height
                                var newX = controlsPosition.x + value.translation.width
                                var newY = controlsPosition.y + value.translation.height
                                newX = max(halfW + margin, min(w - halfW - margin, newX))
                                newY = max(halfH + margin, min(h - halfH - margin, newY))
                                controlsPosition = CGPoint(x: newX, y: newY)
                                controlsDrag = .zero
                                isDraggingControls = false
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                            let w = geometry.size.width
                            let h = geometry.size.height
                            withAnimation(controlVisibilityAnimation) {
                                controlsPosition = CGPoint(x: w / 2, y: h - 82)
                                controlsDrag = .zero
                                }
                            }
                    )
                }
            }
        }
        .background(appBackdrop)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(controlVisibilityAnimation, value: state.hasVideo)
        .animation(controlDragAnimation, value: isDropTargeted)
        .onAppear {
            state.startHideTimer()
            setupKeyboardMonitor()
            let pendingURLs = AppDelegate.takePendingOpenURLs()
            for url in pendingURLs {
                (state as? RiftPlayerState)?.loadVideo(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                interactiveReady = true
            }
            if !state.hasVideo, !reduceMotion {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    promptPulse = 1.0
                }
            }
        }
        .onDisappear {
            state.stopHideTimer()
            NSCursor.unhide()
            cleanupKeyboardMonitor()
            // TODO(Core): la referencia llamaba `state.cleanup()` al salir para
            // liberar buffers/decoders. Eso pertenece a Core/FramePool y Core/Decode.
        }
        .onChange(of: state.isPlaying) {
            state.resetHideTimer()
        }
        .onChange(of: state.hasVideo) { _, hasVideo in
            if hasVideo {
                withAnimation(controlVisibilityAnimation) {
                    promptPulse = 0
                }
                state.resetHideTimer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .riftOpenURLs)) { notification in
            let urls = notification.userInfo?["urls"] as? [URL] ?? []
            handleOpenURLs(urls)
        }
        .onReceive(NotificationCenter.default.publisher(for: .riftOpenVideo)) { _ in
            (state as? RiftPlayerState)?.openVideo()
        }
        // TODO(Core): la referencia exponía `.focusedValue(\.playerState, state)`
        // para que los comandos de menú de RiftApp leyeran el estado de
        // reproducción. Depende del tipo concreto de estado de Core.
    }

    // MARK: - Video placeholder (UI-only preview)

    private var videoPlaceholder: some View {
        ZStack {
            RiftPalette.midnight
            VStack(spacing: 12) {
                Image(systemName: "play.tv")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(RiftPalette.luminousGradient)
                Text(NSLocalizedString("Video pipeline not connected", comment: ""))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var videoContentView: some View {
        if let rift = state as? RiftPlayerState, let dl = rift.displayLayer {
            HDRDisplayView(displayLayer: dl, videoGravity: presentationMode.videoGravity)
        } else if let rift = state as? RiftPlayerState, let p = rift.player {
            PlayerView(player: p, videoGravity: presentationMode.videoGravity)
        } else {
            videoPlaceholder
        }
    }

    private var topPlayerControls: some View {
        HStack(spacing: 2) {
            TopChromeButton(
                systemName: presentationMode.icon,
                accessibilityLabel: NSLocalizedString("Toggle video presentation", comment: "")
            ) {
                withAnimation(controlDragAnimation) {
                    presentationMode = presentationMode == .fit ? .fill : .fit
                }
            }

            TopChromeButton(
                systemName: "ellipsis",
                accessibilityLabel: NSLocalizedString("More playback options", comment: "")
            ) {
                showPlaybackOptions.toggle()
            }
            .popover(isPresented: $showPlaybackOptions, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                Button {
                    (state as? RiftPlayerState)?.openVideo()
                } label: {
                    Label(NSLocalizedString("Open Video...", comment: ""), systemImage: "folder")
                }

                Button {
                    (state as? RiftPlayerState)?.addVideosToPlaylist()
                } label: {
                    Label(NSLocalizedString("Add to Playlist...", comment: ""), systemImage: "text.badge.plus")
                }

                if let rift = state as? RiftPlayerState, !rift.recentVideos.isEmpty {
                    Menu(NSLocalizedString("Recent", comment: "")) {
                        ForEach(rift.recentVideos) { video in
                            Button(video.title) {
                                rift.loadVideo(video.url)
                            }
                        }

                        Divider()

                        Button(NSLocalizedString("Clear Recent Videos", comment: ""), role: .destructive) {
                            rift.clearRecentVideos()
                        }
                    }
                }

                if let rift = state as? RiftPlayerState, !rift.playlist.isEmpty {
                    Menu(NSLocalizedString("Playlist", comment: "")) {
                        ForEach(rift.playlist) { item in
                            Button {
                                rift.playPlaylistItem(item)
                            } label: {
                                Label(item.title, systemImage: item.id == rift.activePlaylistItemID ? "play.fill" : "play")
                            }
                        }

                        Divider()

                        Button(NSLocalizedString("Previous Video", comment: "")) {
                            rift.playPreviousPlaylistItem()
                        }
                        .disabled(rift.playlist.first?.id == rift.activePlaylistItemID)

                        Button(NSLocalizedString("Next Video", comment: "")) {
                            rift.playNextPlaylistItem()
                        }
                        .disabled(rift.playlist.last?.id == rift.activePlaylistItemID)
                    }
                }

                Divider()

                if let rift = state as? RiftPlayerState {
                    Button {
                        rift.addMarker()
                    } label: {
                        Label(NSLocalizedString("Add Marker", comment: ""), systemImage: "bookmark.badge.plus")
                    }

                    if !rift.markers.isEmpty {
                        Menu(NSLocalizedString("Markers", comment: "")) {
                            ForEach(rift.markers) { marker in
                                Button {
                                    rift.seek(to: marker.time)
                                } label: {
                                    Text(marker.title)
                                }
                            }
                        }
                    }

                    if !rift.chapters.isEmpty {
                        Menu(NSLocalizedString("Chapters", comment: "")) {
                            ForEach(Array(rift.chapters.enumerated()), id: \.offset) { index, chapter in
                                Button {
                                    rift.seek(to: chapter.start)
                                } label: {
                                    Text("\(index + 1). \(chapter.title)  \(rift.formattedTime(chapter.start))")
                                }
                            }
                        }
                    }

                    Button {
                        showTechnicalInfo = true
                    } label: {
                        Label(NSLocalizedString("Technical Info", comment: ""), systemImage: "info.circle")
                    }
                    .disabled(rift.technicalInfo == nil)

                    Menu(NSLocalizedString("Audio Sync", comment: "")) {
                        ForEach([-0.5, -0.25, -0.1, 0.0, 0.1, 0.25, 0.5], id: \.self) { offset in
                            Button {
                                rift.setAudioSyncOffset(offset)
                            } label: {
                                Label(
                                    audioSyncTitle(for: offset),
                                    systemImage: abs(rift.audioSyncOffset - offset) < 0.001 ? "checkmark" : "circle"
                                )
                            }
                        }
                    }

                    Divider()

                    Button {
                        rift.openExternalSubtitles()
                    } label: {
                        Label(NSLocalizedString("Load Subtitle File...", comment: ""), systemImage: "captions.bubble")
                    }

                    if let subtitleName = rift.externalSubtitleName {
                        Button(role: .destructive) {
                            rift.removeExternalSubtitles()
                        } label: {
                            Label("\(NSLocalizedString("Remove External Subtitles", comment: "")) (\(subtitleName))", systemImage: "captions.bubble.fill")
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    state.closeVideo()
                } label: {
                    Label(NSLocalizedString("Close Video", comment: ""), systemImage: "xmark")
                }
                    }
                    .padding(10)
                }
                .frame(width: 290, height: 360)
                }

            if let rift = state as? RiftPlayerState, rift.isPictureInPictureAvailable {
                TopChromeButton(
                    systemName: rift.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                    accessibilityLabel: NSLocalizedString("Picture in Picture", comment: "")
                ) {
                    rift.togglePictureInPicture()
                }
            }

            TopChromeButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                accessibilityLabel: NSLocalizedString("Toggle full screen", comment: "")
            ) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .fixedSize()
        .padding(4)
        .background {
            GlassBackground(cornerRadius: 19, effectOpacity: 0.34)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .popover(isPresented: $showTechnicalInfo, arrowEdge: .top) {
            technicalInfoPanel
        }
    }

    @ViewBuilder
    private var technicalInfoPanel: some View {
        if let rift = state as? RiftPlayerState, let info = rift.technicalInfo {
            VStack(alignment: .leading, spacing: 16) {
                Text(info.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    technicalInfoRow(NSLocalizedString("Resolution", comment: ""), info.resolution)
                    technicalInfoRow(NSLocalizedString("Video", comment: ""), info.videoCodec)
                    technicalInfoRow(NSLocalizedString("Frame Rate", comment: ""), info.frameRate)
                    technicalInfoRow(NSLocalizedString("Color", comment: ""), info.colorSpace)
                    technicalInfoRow(NSLocalizedString("Audio", comment: ""), info.audio)
                    technicalInfoRow(NSLocalizedString("Duration", comment: ""), info.duration)
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(18)
            .frame(width: 320, alignment: .leading)
            .background {
                GlassBackground(cornerRadius: 16, effectOpacity: 0.28)
            }
        }
    }

    private func technicalInfoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func audioSyncTitle(for offset: Double) -> String {
        guard offset != 0 else { return NSLocalizedString("In Sync", comment: "") }
        return String(format: "%@ %.0f ms", offset > 0 ? "+" : "-", abs(offset) * 1_000)
    }

    // MARK: - Keyboard & mouse monitoring

    private func setupKeyboardMonitor() {
        cleanupKeyboardMonitor()
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak state] event in
                state?.resetHideTimer()
                return event
            }
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state] event in
            guard let state, state.hasVideo else { return event }

            switch event.keyCode {
            case 123: // Left arrow
                state.seek(by: event.modifierFlags.contains(.shift) ? -60 : -10)
                return nil
            case 124: // Right arrow
                state.seek(by: event.modifierFlags.contains(.shift) ? 60 : 10)
                return nil
            case 125: // Down arrow
                state.setVolume(state.volume - 0.05)
                return nil
            case 126: // Up arrow
                state.setVolume(state.volume + 0.05)
                return nil
            case 53: // Escape
                state.closeVideo()
                NSCursor.unhide()
                return nil
            case 3: // F
                if !event.modifierFlags.contains(.command) { return event }
                if let window = NSApp.keyWindow {
                    window.toggleFullScreen(nil)
                }
                return nil
            case 46: // M
                if !event.modifierFlags.contains(.command) { return event }
                state.setVolume(state.volume > 0 ? 0 : 0.72)
                return nil
            case 4: // H - toggle controls
                withAnimation(controlVisibilityAnimation) {
                    state.areControlsVisible.toggle()
                }
                return nil
            case 18...21: // Number keys 1-4
                let speeds: [Float] = [1.0, 1.5, 2.0, 0.5]
                let idx = Int(event.keyCode - 18)
                guard idx < speeds.count else { return event }
                let rate = speeds[idx]
                state.playbackRate = rate
                if state.isPlaying {
                    // TODO(Core): la referencia fijaba `state.player.rate = rate`
                    // en el AVPlayer. Eso es Core/Scheduler + Rendering; no se
                    // recrea en la capa UI.
                }
                return nil
            default:
                return event
            }
        }
        keyboardEventMonitor = monitor
    }

    private func cleanupKeyboardMonitor() {
        if let monitor = keyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardEventMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Ambient particles

    private func generateParticles() {
        var newParticles: [AmbientParticle] = []
        for _ in 0..<96 {
            newParticles.append(AmbientParticle(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                size: CGFloat.random(in: 1.5...5.0),
                speed: CGFloat.random(in: 0.08...0.35),
                opacity: Double.random(in: 0.12...0.55),
                delay: Double.random(in: 0...20)
            ))
        }
        particles = newParticles
    }

    private var ambientParticles: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for p in particles {
                    let drift = sin(time * 0.25 + p.delay * 1.7) * 28
                    let rise = fmod(time * p.speed + p.delay * 25, size.height * 1.4)
                    let xPos = (p.x * size.width * 0.9 + size.width * 0.05) + drift
                    let yPos = size.height - rise + size.height * 0.2
                    let breathe = 0.5 + 0.5 * sin(time * 0.4 + p.delay * 2.3)
                    let particleOpacity = p.opacity * breathe

                    var dotContext = context
                    dotContext.opacity = particleOpacity
                    dotContext.fill(
                        Path(ellipseIn: CGRect(x: xPos, y: yPos, width: p.size, height: p.size)),
                        with: .color(.white.opacity(0.62))
                    )
                }
            }
        }
        .drawingGroup()
    }

    private var appBackdrop: some View {
        ZStack {
            if state.hasVideo {
                Color.black
            } else {
                GlassBackground(
                    cornerRadius: 0,
                    blendingMode: .behindWindow,
                    effectOpacity: 0.58
                )

                Color.black.opacity(isDropTargeted ? 0.12 : 0.20)
            }
        }
        .ignoresSafeArea()
    }

    private var controlVisibilityAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.26)
    }

    private var controlDragAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.25, 1, 0.5, 1, duration: 0.16)
    }

    private var filmGrainOverlay: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 6)) { timeline in
            let seed = Int(timeline.date.timeIntervalSinceReferenceDate * 6)
            Canvas { context, size in
                for row in 0..<Int(size.height / 4) {
                    for col in 0..<Int(size.width / 3) {
                        let hash = seed ^ (row * 137) ^ (col * 251)
                        let gray = Double((hash & 0xFF)) / 512.0
                        let rect = CGRect(
                            x: CGFloat(col) * 3,
                            y: CGFloat(row) * 4,
                            width: 2.5,
                            height: 3.5
                        )
                        context.fill(
                            Path(rect),
                            with: .color(.white.opacity(gray * 0.06))
                        )
                    }
                }
            }
            .blendMode(.overlay)
        }
    }

    private var openVideoPrompt: some View {
        Button {
            (state as? RiftPlayerState)?.openVideo()
        } label: {
            VStack(spacing: 22) {
                RiftBrandMark(size: 100)
                    .scaleEffect(isDropTargeted ? 1.06 : 1 + promptPulse * 0.018)
                    .shadow(color: RiftPalette.blue.opacity(0.35 + promptPulse * 0.12), radius: 24, x: 0, y: 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(isDropTargeted ? 0.48 : 0.22), lineWidth: 0.5)
                    }

                VStack(spacing: 10) {
                    Text(NSLocalizedString("Open Video", comment: ""))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text(NSLocalizedString("Drop a file here or click to browse", comment: ""))
                        .font(.system(size: 15, weight: .regular))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.48))

                    // TODO(Core): la referencia mostraba aquí `state.statusMessage`
                    // y `state.conversionProgress` del pipeline (progreso de carga/
                    // transcodificación). Sin Core/ esos estados no existen.
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitleOverlay(_ text: String) -> some View {
        VStack {
            Spacer()

            Text(text)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.95), radius: 4, x: 0, y: 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background {
                    GlassBackground(cornerRadius: 12)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(RiftPalette.cyan.opacity(0.24), lineWidth: 0.5)
                        }
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 34)
                .padding(.bottom, state.areControlsVisible ? 154 : 58)
        }
        .allowsHitTesting(false)
        .animation(controlVisibilityAnimation, value: state.areControlsVisible)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?

            if let data = item as? Data {
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                droppedURL = url
            } else if let string = item as? String {
                droppedURL = URL(string: string)
            } else {
                droppedURL = nil
            }

            guard droppedURL != nil else { return }

            Task { @MainActor in
                // TODO(Core): la referencia llamaba `state.loadVideo(droppedURL)`.
                // La carga/decodificación del video pertenece a Core/Demux +
                // Core/Decode; aquí solo se acepta el drop y se marca el hueco.
            }
        }

        return true
    }

    private func handleOpenURLs(_ urls: [URL]) {
        guard let url = urls.first else { return }
        (state as? RiftPlayerState)?.loadVideo(url)
        AppDelegate.bringPlayerWindowToFront()
    }
}
