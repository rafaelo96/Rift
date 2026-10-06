import AppKit
import AVFoundation
import SwiftUI

private final class FloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

    init(state: RiftPlayerState, displayLayer: AVSampleBufferDisplayLayer, aspectRatio: CGFloat) {
        self.state = state
        self.displayLayer = displayLayer
        sourceWindow = NSApp.keyWindow
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
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false
        )
        super.init()
        panel.title = "Rift — Picture in Picture"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
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
    }

    func show() {
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
        // Restore before removing the hosting view, including when paused.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        sourceLayer?.addSublayer(displayLayer)
        displayLayer.frame = sourceLayer?.bounds ?? sourceFrame
        displayLayer.videoGravity = sourceGravity
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
            Color.black.onTapGesture { hovering = true }
            HDRDisplayView(displayLayer: displayLayer, videoGravity: .resizeAspect)
                .allowsHitTesting(false)
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(12)
            .foregroundStyle(.white)
            .opacity(hovering || scrubbing || timelineFocused || !state.isPlaying ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
