import AppKit
import AVFoundation
import SwiftUI

private final class FloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Captures video-area drags without intercepting the SwiftUI controls above it.
private struct FloatingWindowDragSurface: NSViewRepresentable {
    var edgesOnly = false
    let revealControls: () -> Void

    func makeNSView(context: Context) -> DragView {
        DragView(edgesOnly: edgesOnly, revealControls: revealControls)
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.revealControls = revealControls
    }

    final class DragView: NSView {
        var revealControls: () -> Void
        private let edgesOnly: Bool
        private var dragStart: NSPoint?
        private var initialFrame: CGRect?
        private var resizeEdges: FloatingWindowGeometry.Edges = []
        override var mouseDownCanMoveWindow: Bool { false }

        init(edgesOnly: Bool, revealControls: @escaping () -> Void) {
            self.edgesOnly = edgesOnly
            self.revealControls = revealControls
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func edges(at point: NSPoint) -> FloatingWindowGeometry.Edges {
            var edges: FloatingWindowGeometry.Edges = []
            if point.x <= 8 { edges.insert(.left) }
            if point.x >= bounds.maxX - 8 { edges.insert(.right) }
            if point.y <= 8 { edges.insert(.bottom) }
            if point.y >= bounds.maxY - 8 { edges.insert(.top) }
            return edges
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), !edgesOnly || !edges(at: local).isEmpty else { return nil }
            return self
        }

        override func resetCursorRects() {
            guard edgesOnly else { return }
            addCursorRect(NSRect(x: 0, y: 8, width: 8, height: max(bounds.height - 16, 0)), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.maxX - 8, y: 8, width: 8, height: max(bounds.height - 16, 0)), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 8), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: 0, y: bounds.maxY - 8, width: bounds.width, height: 8), cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStart = window.convertPoint(toScreen: event.locationInWindow)
            initialFrame = window.frame
            resizeEdges = edgesOnly ? edges(at: convert(event.locationInWindow, from: nil)) : []
            revealControls()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let dragStart, let initialFrame else { return }
            let cursor = window.convertPoint(toScreen: event.locationInWindow)
            let delta = CGPoint(x: cursor.x - dragStart.x, y: cursor.y - dragStart.y)
            if resizeEdges.isEmpty {
                window.setFrameOrigin(NSPoint(x: initialFrame.minX + delta.x, y: initialFrame.minY + delta.y))
            } else {
                let available = window.screen?.visibleFrame.size ?? CGSize(width: 1920, height: 1080)
                window.setFrame(FloatingWindowGeometry.resize(initialFrame, delta: delta,
                    edges: resizeEdges, minimum: window.contentMinSize, maximum: available), display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                window.invalidateCursorRects(for: self)
            }
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            initialFrame = nil
            resizeEdges = []
        }
    }
}

/// Moves the existing renderer between windows; no second decoder or frame queue.
@MainActor
final class FloatingPictureInPictureController: NSObject, NSWindowDelegate {
    private weak var state: RiftPlayerState?
    private weak var sourceWindow: NSWindow?
    private let displayLayer: AVSampleBufferDisplayLayer
    private let sourceLayer: CALayer?
    private let sourceFrame: CGRect
    private let sourceGravity: AVLayerVideoGravity
    private let panel: FloatingVideoPanel
    private var dismissed = false

    init(state: RiftPlayerState, displayLayer: AVSampleBufferDisplayLayer, aspectRatio: CGFloat) {
        self.state = state
        self.displayLayer = displayLayer
        sourceWindow = (displayLayer.superlayer?.delegate as? NSView)?.window
            ?? NSApp.mainWindow ?? NSApp.keyWindow
        sourceLayer = displayLayer.superlayer
        sourceFrame = displayLayer.frame
        sourceGravity = displayLayer.videoGravity
        let screen = sourceWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let ratio = min(max(aspectRatio, 0.25), 4)
        let width = min(max(480, 148 * ratio), visible.width * 0.75, visible.height * 0.75 * ratio)
        let size = CGSize(width: width, height: width / ratio)
        panel = FloatingVideoPanel(
            contentRect: CGRect(x: visible.maxX - size.width - 20,
                                y: visible.minY + 20, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        super.init()
        panel.title = "Rift — Picture in Picture"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentAspectRatio = CGSize(width: ratio, height: 1)
        let minimumWidth = min(max(260, 148 * ratio), width)
        panel.contentMinSize = CGSize(width: minimumWidth, height: minimumWidth / ratio)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingVideoContent(
            state: state, displayLayer: displayLayer,
            restore: { [weak self] in self?.restore() }
        ))
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let sourceWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(sourceClosed),
                name: NSWindow.willCloseNotification, object: sourceWindow)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func sourceClosed(_ notification: Notification) {
        state?.closeFloatingPictureInPicture()
    }

    @objc private func screensChanged(_ notification: Notification) {
        guard !dismissed, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(FloatingWindowGeometry.fit(panel.frame, in: screen.visibleFrame,
            minimum: panel.contentMinSize), display: true)
    }

    func show() {
        guard !dismissed else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        NotificationCenter.default.removeObserver(self)
        panel.delegate = nil
        // Restore before removing the hosting view, including when paused.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        sourceLayer?.addSublayer(displayLayer)
        displayLayer.frame = sourceLayer?.bounds ?? sourceFrame
        displayLayer.videoGravity = sourceGravity
        sourceWindow?.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func restore() {
        let window = sourceWindow
        state?.closeFloatingPictureInPicture()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state?.closeFloatingPictureInPicture()
        return false
    }
}

private struct FloatingVideoContent: View {
    @ObservedObject var state: RiftPlayerState
    let displayLayer: AVSampleBufferDisplayLayer
    let restore: () -> Void
    @State private var hovering = true
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var hideControlsTask: Task<Void, Never>?
    @AccessibilityFocusState private var timelineFocused: Bool

    private var position: Double { scrubbing ? scrubTime : state.currentTime }

    var body: some View {
        ZStack {
            Color.black
            HDRDisplayView(displayLayer: displayLayer, videoGravity: .resizeAspect)
                .allowsHitTesting(false)
            FloatingWindowDragSurface { hovering = true }
            if let text = state.currentSubtitleText, !text.isEmpty {
                GeometryReader { geometry in
                    VStack {
                        Spacer(minLength: 0)
                        SubtitleCaption(text: text,
                            fontSize: max(12, state.subtitleFontSize * min(geometry.size.width / 780, 1)),
                            textColor: SubtitleColors.color(state.subtitleTextColorHex),
                            backgroundStyle: state.subtitleBackgroundStyle,
                            backgroundColor: SubtitleColors.color(state.subtitleBackgroundColorHex),
                            backgroundOpacity: state.subtitleBackgroundOpacity)
                            .lineLimit(3)
                            .padding(.horizontal, 12)
                            .padding(.bottom, (hovering || scrubbing || timelineFocused || !state.isPlaying) ? 110 : max(12, state.subtitleBottomInset * geometry.size.height / 480))
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .allowsHitTesting(false)
            }
            VStack {
                HStack {
                    control("xmark", label: "Close Picture in Picture") {
                        state.closeFloatingPictureInPicture()
                    }
                    Spacer()
                    control("pip.exit", label: "Restore video window", action: restore)
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    HStack(spacing: 24) {
                        control("gobackward.10", label: "Skip Back 10s") { state.seek(by: -10) }
                        control(state.isPlaying ? "pause.fill" : "play.fill",
                                label: state.isPlaying ? "Pause" : "Play") { state.togglePlay() }
                        control("goforward.10", label: "Skip Forward 10s") { state.seek(by: 10) }
                    }
                    HStack(spacing: 8) {
                        Text(state.formattedTime(position))
                        Slider(value: Binding(
                            get: { min(max(position, 0), max(state.duration, 0.01)) },
                            set: { scrubTime = $0 }
                        ), in: 0...max(state.duration, 0.01), onEditingChanged: { editing in
                            if editing {
                                scrubTime = state.currentTime
                                scrubbing = true
                            } else {
                                if scrubbing { state.seek(to: scrubTime) }
                                scrubbing = false
                            }
                        })
                        .disabled(state.duration <= 0)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(state.formattedTime(position))
                        .accessibilityFocused($timelineFocused)
                        Text(state.formattedTime(state.duration))
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .padding(12)
                .background(GlassBackground(cornerRadius: 18))
            }
            .padding(12)
            .foregroundStyle(.white)
            .opacity(hovering || scrubbing || timelineFocused || !state.isPlaying ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay { FloatingWindowDragSurface(edgesOnly: true) { hovering = true } }
        .onHover { inside in
            hideControlsTask?.cancel()
            if inside {
                hovering = true
            } else {
                hideControlsTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    hovering = false
                }
            }
        }
        .onDisappear { hideControlsTask?.cancel() }
        .onExitCommand { state.closeFloatingPictureInPicture() }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(GlassBackground(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
