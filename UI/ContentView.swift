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
        if let url = Bundle.module.url(forResource: "Rift-icon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let url = Bundle.module.url(forResource: "Rift-icon", withExtension: "png"),
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
            if displayLayer?.superlayer === layer {
                displayLayer?.videoGravity = videoGravity
            }
        }
    }

    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            guard oldValue !== displayLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if let old = oldValue, old.superlayer === self.layer {
                old.removeFromSuperlayer()
            }
            if let l = displayLayer {
                self.layer?.addSublayer(l)
                l.videoGravity = videoGravity
                l.needsDisplayOnBoundsChange = true
                l.isOpaque = true
                l.frame = bounds
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
        if let displayLayer, displayLayer.superlayer === layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let l = displayLayer, l.superlayer === layer {
            l.frame = bounds
        }
    }
}

struct HDRDisplayView: NSViewRepresentable {
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

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 22, height: 22)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Círculo de vidrio para el botón de menú "…": `Menu` no acepta el estilo de
/// botón de vidrio, así que recibe el mismo material de forma explícita.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
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
        .riftGlassButton()
        .buttonBorderShape(.circle)
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
                    .contextMenu { videoContextMenu }
                    .overlay(alignment: .topTrailing) {
                        if interactiveReady {
                            topPlayerControls
                                .zIndex(1)
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                .opacity(state.areControlsVisible ? 1.0 : 0.0)
                                .scaleEffect(reduceMotion ? 1 : (state.areControlsVisible ? 1 : 0.985))
                                .offset(y: reduceMotion || state.areControlsVisible ? 0 : 10)
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

            if state.hasVideo, let rift = state as? RiftPlayerState, !rift.isPictureInPictureActive {
                VideoCurtainOverlay(model: rift.feedback)
                    .ignoresSafeArea()
            }

            if state.hasVideo,
               !((state as? RiftPlayerState)?.isPictureInPictureActive ?? false),
               let subtitleText = state.currentSubtitleText,
               !subtitleText.isEmpty {
                subtitleOverlay(subtitleText)
                    .transition(.opacity)
            }

            if state.hasVideo, let rift = state as? RiftPlayerState, !rift.isPictureInPictureActive {
                PlayerFeedbackOverlay(model: rift.feedback)
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

            if state.hasVideo, let rift = state as? RiftPlayerState, !rift.isPictureInPictureActive,
               let upNext = rift.upNext {
                UpNextCard(countdown: upNext, playNow: rift.playUpNextNow, cancel: rift.cancelUpNext)
                    .padding(.trailing, cardTrailingInset(rift))
                    .padding(.bottom, 150)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
            if state.hasVideo, let rift = state as? RiftPlayerState, rift.isPlaylistPanelVisible {
                // Termina encima de la barra de controles para no taparla.
                PlaylistPanel(state: rift)
                    .padding(.top, 52)
                    .padding(.bottom, 146)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }

            if state.hasVideo, let rift = state as? RiftPlayerState, !rift.isPictureInPictureActive,
               rift.upNext == nil, let resumedAt = rift.resumedAt {
                ResumedCard(positionText: rift.formattedTime(resumedAt),
                            restart: rift.restartFromBeginning,
                            dismiss: rift.dismissResumedNotice,
                            hold: rift.holdResumedNotice)
                    .padding(.trailing, cardTrailingInset(rift))
                    .padding(.bottom, 150)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .background(appBackdrop)
        .navigationTitle((state as? RiftPlayerState)?.windowTitle ?? "Rift")
        .onChange(of: (state as? RiftPlayerState)?.openFileURL, initial: true) { _, url in
            // Ícono del archivo en la barra de título (⌘-clic muestra su carpeta).
            AppDelegate.playerWindow?.representedURL = url
        }
        .background {
            if let rift = state as? RiftPlayerState {
                AutomaticPictureInPictureObserver(state: rift)
                    .frame(width: 0, height: 0)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(controlVisibilityAnimation, value: state.hasVideo)
        .animation(.easeOut(duration: 0.25), value: (state as? RiftPlayerState)?.upNext?.title)
        .animation(.easeOut(duration: 0.25), value: (state as? RiftPlayerState)?.resumedAt)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86),
                   value: (state as? RiftPlayerState)?.isPlaylistPanelVisible)
        .animation(controlDragAnimation, value: isDropTargeted)
        .onAppear {
            state.startHideTimer()
            setupKeyboardMonitor()
            AppDelegate.playerState = state as? RiftPlayerState
            let pendingURLs = AppDelegate.takePendingOpenURLs()
            if !pendingURLs.isEmpty {
                (state as? RiftPlayerState)?.replacePlaylist(with: pendingURLs)
            } else {
                (state as? RiftPlayerState)?.restoreLastSessionIfAvailable()
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
        .onReceive(NotificationCenter.default.publisher(for: .riftTogglePresentation)) { _ in
            withAnimation(controlDragAnimation) {
                presentationMode = presentationMode == .fit ? .fill : .fit
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .riftShowTechnicalInfo)) { _ in
            state.areControlsVisible = true
            showTechnicalInfo = true
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
            HDRDisplayView(displayLayer: rift.isPictureInPictureActive ? nil : dl,
                           videoGravity: presentationMode.videoGravity)
                .overlay {
                    if rift.isPictureInPictureActive {
                        pictureInPicturePlaceholder
                            .transition(
                                .asymmetric(
                                    insertion: .opacity
                                        .combined(with: .scale(scale: 0.92))
                                        .animation(pipTransitionAnimation),
                                    removal: .opacity
                                        .animation(pipTransitionAnimation)
                                )
                            )
                    }
                }
                .animation(pipTransitionAnimation, value: rift.isPictureInPictureActive)
        } else if let rift = state as? RiftPlayerState, let p = rift.player {
            PlayerView(player: p, videoGravity: presentationMode.videoGravity)
        } else {
            videoPlaceholder
        }
    }

    private var pictureInPicturePlaceholder: some View {
        ZStack {
            // Frosted dark glass — matches macOS system PiP placeholder feel
            Color.black.opacity(0.72)
                .background(.ultraThinMaterial)

            // Subtle radial vignette
            RadialGradient(
                colors: [.clear, .black.opacity(0.18)],
                center: .center,
                startRadius: 80,
                endRadius: 420
            )

            VStack(spacing: 18) {
                Image(systemName: "pip")
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(.white.opacity(0.64))
                    .symbolRenderingMode(.hierarchical)

                Text(NSLocalizedString("This video is playing in picture in picture.", comment: ""))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// macOS-native easing for PiP enter/exit — mirrors the system window
    /// minimize/restore curve (fast out, gentle settle).
    private var pipTransitionAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    }

    /// Clic derecho sobre el video: los comandos más usados de la barra de menús.
    @ViewBuilder
    private var videoContextMenu: some View {
        if let rift = state as? RiftPlayerState {
            Button(rift.isPlaying ? "Pause" : "Play") { rift.togglePlay() }
            Divider()
            Toggle("Frame+", isOn: Binding(
                get: { rift.isFramePlusRequested },
                set: { rift.setInterpolationMode($0 ? .enabled : .disabled) }
            ))
            Toggle("Super Resolution", isOn: Binding(
                get: { rift.superResolutionMode != .off },
                set: { rift.setSuperResolutionMode($0 ? .strong : .off) }
            ))
            Button(presentationMode == .fit ? "Fill Window" : "Fit to Window") {
                withAnimation(controlDragAnimation) {
                    presentationMode = presentationMode == .fit ? .fill : .fit
                }
            }
            Divider()
            if rift.isPictureInPictureAvailable {
                Button(rift.isPictureInPictureActive ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                    rift.togglePictureInPicture()
                }
            }
            Button("Technical Info") { showTechnicalInfo = true }
                .disabled(rift.technicalInfo == nil)
            Divider()
            Button("Close Video") { rift.closeVideo() }
        }
    }

    /// Menú "…": comandos del video actual como menú nativo de macOS (se ajusta
    /// a su contenido, se navega con teclado y usa el material del sistema).
    @ViewBuilder
    private var playbackOptionsMenu: some View {
        if let rift = state as? RiftPlayerState {
            if let message = rift.statusMessage, message != "Ready" {
                Text(message)
                Divider()
            }

            Section {
                Button(NSLocalizedString("Open Video…", comment: ""), systemImage: "folder") {
                    rift.openVideo()
                }
                Button(NSLocalizedString("Add to Playlist…", comment: ""), systemImage: "text.badge.plus") {
                    rift.addVideosToPlaylist()
                }
                if !rift.recentVideos.isEmpty {
                    Menu(NSLocalizedString("Recent", comment: ""), systemImage: "clock") {
                        ForEach(rift.recentVideos) { video in
                            Button(video.title) { rift.loadVideo(video.url) }
                        }
                        Divider()
                        Button(NSLocalizedString("Clear Recent Videos", comment: ""), role: .destructive) {
                            rift.clearRecentVideos()
                        }
                    }
                }
                Button(rift.isPlaylistPanelVisible ? NSLocalizedString("Hide Playlist", comment: "")
                                                   : NSLocalizedString("Show Playlist", comment: ""),
                       systemImage: "sidebar.right") {
                    rift.togglePlaylistPanel()
                }
                if !rift.playlist.isEmpty {
                    Menu(NSLocalizedString("Playlist", comment: ""), systemImage: "list.bullet") {
                        ForEach(rift.playlist) { item in
                            Toggle(item.title, isOn: Binding(
                                get: { item.id == rift.activePlaylistItemID },
                                set: { _ in rift.playPlaylistItem(item) }
                            ))
                        }
                        Divider()
                        Button(NSLocalizedString("Previous Video", comment: "")) { rift.playPreviousPlaylistItem() }
                            .disabled(rift.playlist.first?.id == rift.activePlaylistItemID)
                        Button(NSLocalizedString("Next Video", comment: "")) { rift.playNextPlaylistItem() }
                            .disabled(rift.playlist.last?.id == rift.activePlaylistItemID)
                    }
                }
            }

            Section {
                Button(NSLocalizedString("Add Marker", comment: ""), systemImage: "bookmark") {
                    rift.addMarker()
                }
                if !rift.markers.isEmpty {
                    Menu(NSLocalizedString("Markers", comment: ""), systemImage: "bookmark.fill") {
                        ForEach(rift.markers) { marker in
                            Button(marker.title) { rift.seek(to: marker.time) }
                        }
                    }
                }
                if !rift.chapters.isEmpty {
                    Menu(NSLocalizedString("Chapters", comment: ""), systemImage: "list.number") {
                        ForEach(Array(rift.chapters.enumerated()), id: \.offset) { index, chapter in
                            Button("\(index + 1). \(chapter.title)  \(rift.formattedTime(chapter.start))") {
                                rift.seek(to: chapter.start)
                            }
                        }
                    }
                }
            }

            Button(NSLocalizedString("Technical Info", comment: ""), systemImage: "info.circle") {
                showTechnicalInfo = true
            }
            .disabled(rift.technicalInfo == nil)

            Divider()
            Button(NSLocalizedString("Close Video", comment: ""), systemImage: "xmark", role: .destructive) {
                rift.closeVideo()
            }
        }
    }

    private var topPlayerControls: some View {
        GlassGroup(spacing: 2) {
        HStack(spacing: 2) {
            TopChromeButton(
                systemName: presentationMode.icon,
                // Dice lo que hará el clic, no el estado actual.
                accessibilityLabel: presentationMode == .fit
                    ? NSLocalizedString("Fill Window", comment: "Zoom the video to cover the window")
                    : NSLocalizedString("Fit to Window", comment: "Show the whole video inside the window")
            ) {
                withAnimation(controlDragAnimation) {
                    presentationMode = presentationMode == .fit ? .fill : .fit
                }
            }

            Menu {
                playbackOptionsMenu
            } label: {
                TopChromeGlyph(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28, height: 28)
            .modifier(GlassCircle())
            .accessibilityLabel(NSLocalizedString("More playback options", comment: ""))
            .help(NSLocalizedString("More playback options", comment: ""))

            if let rift = state as? RiftPlayerState, rift.isPictureInPictureAvailable {
                TopChromeButton(
                    systemName: rift.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                    accessibilityLabel: NSLocalizedString("Picture in Picture", comment: "")
                ) {
                    rift.togglePictureInPicture()
                }
                .animation(pipTransitionAnimation, value: rift.isPictureInPictureActive)
            }

            TopChromeButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                accessibilityLabel: NSLocalizedString("Toggle full screen", comment: "")
            ) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        }
        .fixedSize()
        .padding(6)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .popover(isPresented: $showTechnicalInfo, arrowEdge: .top) {
            technicalInfoPanel
                .background(VideoOverlayGlass(cornerRadius: 16))
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
                    // Lo que antes mostraba la barra: fps entregados y objetivo de Frame+.
                    ClockReader(clock: rift.clock) { clock in
                        technicalInfoRow(NSLocalizedString("Output", comment: "Frames delivered per second"),
                                         outputRateText(rift, fps: clock.renderingFPS))
                    }
                }
            }
            .padding(18)
            .frame(width: 320, alignment: .leading)
        }
    }

    private func outputRateText(_ rift: RiftPlayerState, fps: Double) -> String {
        guard rift.interpolationMode != .disabled, !rift.isFramePlusPreparing else {
            return String(format: NSLocalizedString("%.0f fps", comment: ""), fps)
        }
        return String(format: NSLocalizedString("%.0f fps · Frame+ target %.0f fps", comment: ""),
                      fps, rift.targetRenderingFPS)
    }

    private func technicalInfoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
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
        // Los atajos del reproductor viven en la barra de menús (RiftCommands).
        // Aquí solo quedan Esc (salir de pantalla completa) y ⌘F, que no
        // tienen un comando propio en el menú.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, AppDelegate.isPlayerWindow(window) else { return event }
            switch event.keyCode {
            case 53 where window.styleMask.contains(.fullScreen): // Escape
                window.toggleFullScreen(nil)
                return nil
            case 3 where event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command: // ⌘F
                window.toggleFullScreen(nil)
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
                    effectOpacity: 0.42
                )

                Color.black.opacity(isDropTargeted ? 0.04 : 0.08)
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
        let recents = (state as? RiftPlayerState)?.continueWatching ?? []
        return ZStack {
            // En ventanas estrechas caben menos tarjetas; sin espacio para la
            // fila, se queda solo la apertura.
            ViewThatFits {
                ForEach([4, 3, 2], id: \.self) { count in
                    openVideoStack(recents: Array(recents.prefix(count)))
                }
                openVideoHero(markSize: 118)
            }
            .padding(.bottom, 24)

            VStack {
                Spacer()

                Divider()

                Label(NSLocalizedString("Supports MKV, MP4, HEVC, AV1, 4K", comment: ""), systemImage: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(controlDragAnimation, value: isDropTargeted)
    }

    /// Las tarjetas de abajo a la derecha se apartan del panel de lista.
    private func cardTrailingInset(_ rift: RiftPlayerState) -> CGFloat {
        rift.isPlaylistPanelVisible ? 24 + 330 + 14 : 24
    }

    private func openVideoStack(recents: [RecentVideo]) -> some View {
        VStack(spacing: 22) {
            openVideoHero(markSize: recents.isEmpty ? 118 : 76)
            if let rift = state as? RiftPlayerState, !recents.isEmpty {
                ContinueWatchingRow(videos: recents,
                                    thumbnail: { await rift.thumbnail(forRecent: $0) },
                                    open: { rift.loadVideo($0.url) })
            }
        }
    }

    private func openVideoHero(markSize: CGFloat) -> some View {
            VStack(spacing: 18) {
                RiftBrandMark(size: markSize)
                    .scaleEffect(isDropTargeted ? 1.04 : 1)
                    .shadow(color: Color.accentColor.opacity(0.32), radius: 22, y: 8)

                VStack(spacing: 7) {
                    Text(NSLocalizedString("Open Video", comment: ""))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))

                    Text(NSLocalizedString("Drop a video here or click to browse", comment: ""))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    (state as? RiftPlayerState)?.openVideo()
                } label: {
                    Label(NSLocalizedString("Choose Video…", comment: ""), systemImage: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 38)
                }
                .riftGlassButton(prominent: true)
                .controlSize(.large)
            }
    }

    private func subtitleOverlay(_ text: String) -> some View {
        VStack {
            Spacer()

            SubtitleCaption(text: text,
                fontSize: (state as? RiftPlayerState)?.subtitleFontSize ?? 28,
                textColor: SubtitleColors.color((state as? RiftPlayerState)?.subtitleTextColorHex ?? "FFFFFF"),
                backgroundStyle: (state as? RiftPlayerState)?.subtitleBackgroundStyle ?? .liquidGlass,
                backgroundColor: SubtitleColors.color((state as? RiftPlayerState)?.subtitleBackgroundColorHex ?? "000000"),
                backgroundOpacity: (state as? RiftPlayerState)?.subtitleBackgroundOpacity ?? 0.72)
                .frame(maxWidth: 920)
                .padding(.horizontal, 34)
                .padding(.bottom, max((state as? RiftPlayerState)?.subtitleBottomInset ?? 58, state.areControlsVisible ? 154 : 0))
        }
        .allowsHitTesting(false)
        .animation(controlVisibilityAnimation, value: state.areControlsVisible)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        // Cada proveedor entrega su archivo por separado; se espera a todos
        // para armar una sola lista en el orden de Finder.
        let group = DispatchGroup()
        let collected = DroppedURLCollector()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
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
                if let droppedURL, droppedURL.isFileURL { collected.append(droppedURL) }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = AppDelegate.sortedLikeFinder(collected.urls)
                guard !urls.isEmpty else { return }
                (state as? RiftPlayerState)?.replacePlaylist(with: urls)
                AppDelegate.bringPlayerWindowToFront()
            }
        }
        return true
    }

    private func handleOpenURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        (state as? RiftPlayerState)?.replacePlaylist(with: urls)
        AppDelegate.bringPlayerWindowToFront()
    }
}

/// Junta las URLs que los proveedores del arrastre entregan desde otros hilos.
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}
