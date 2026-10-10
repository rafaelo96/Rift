import AppKit
import Decode
import SwiftUI

private final class ResumePlaybackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Presentation only: returns the same responses as the original NSAlert.
@MainActor
enum ResumePlaybackDialog {
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        return Duration.seconds(max(0, seconds).rounded(.down)).formatted(
            .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }

    static func runModal(url: URL, position: Double, duration: Double?,
                         positionText: String, durationText: String?,
                         extractor: VideoThumbnailExtractor,
                         parent: NSWindow?) -> NSApplication.ModalResponse {
        let visible = (parent?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(480, max(280, visible.width - 40))
        let content = ResumePlaybackDialogView(
            url: url, position: position, duration: duration,
            positionText: positionText, durationText: durationText,
            extractor: extractor,
            respond: { NSApp.stopModal(withCode: $0) }
        )
        let host = NSHostingView(rootView: content.frame(width: width))
        let height = host.fittingSize.height
        let panel = ResumePlaybackPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.title = "¿Continuar viendo?"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.contentView = host
        let center = parent.flatMap { $0.isVisible && !$0.isMiniaturized ? $0.frame : nil } ?? visible
        panel.setFrameOrigin(CGPoint(
            x: min(max(center.midX - width / 2, visible.minX), visible.maxX - width),
            y: min(max(center.midY - height / 2, visible.minY), visible.maxY - height)
        ))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        return response
    }
}

struct ResumePlaybackDialogView: View {
    let url: URL
    let position: Double
    let duration: Double?
    let positionText: String
    let durationText: String?
    let extractor: VideoThumbnailExtractor
    let respond: (NSApplication.ModalResponse) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var thumbnail: CGImage?

    private var progress: Double? {
        guard let duration, duration.isFinite, duration > 0, position.isFinite else { return nil }
        return min(max(position / duration, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                preview
                VStack(alignment: .leading, spacing: 7) {
                    Text("¿Continuar viendo?")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(url.lastPathComponent)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(url.lastPathComponent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(durationText.flatMap { progress == nil ? nil : $0 }
                             .map { "\(positionText) de \($0)" }
                             ?? "Última posición: \(positionText)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let progress {
                            ProgressView(value: progress)
                                .accessibilityLabel("Progreso guardado")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    cancelButton
                    Spacer(minLength: 8)
                    restartButton
                    continueButton
                }
                VStack(spacing: 10) {
                    continueButton.frame(maxWidth: .infinity)
                    HStack {
                        cancelButton
                        Spacer()
                        restartButton
                    }
                }
            }
            .controlSize(.regular)
        }
        .padding(22)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            let result = try? await extractor.thumbnail(for: url, at: position)
            guard !Task.isCancelled else { return }
            thumbnail = result?.image
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(.quaternary)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: thumbnail != nil)
    }

    private var continueButton: some View {
        Button("Continuar viendo") { respond(.alertFirstButtonReturn) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private var restartButton: some View {
        Button("Empezar desde el principio") { respond(.alertSecondButtonReturn) }
            .buttonStyle(.bordered)
    }

    private var cancelButton: some View {
        Button("Cancelar") { respond(.alertThirdButtonReturn) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
    }
}
