import Contracts
import SwiftUI

// MARK: - Feedback model
//
// Avisos breves de acciones del usuario y de cambios de Frame+. Vive fuera de
// RiftPlayerState como ObservableObject propio: publicar un aviso solo invalida
// esta capa, no el ContentView completo.

enum PlayerActionFeedback: Equatable {
    case play
    case pause
    case seek(Double)
    case volume(Double)
    case rate(Float)

    var symbol: String {
        switch self {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .seek(let delta):
            let magnitude = Int(abs(delta).rounded())
            let base = delta < 0 ? "gobackward" : "goforward"
            return [10, 15, 30, 45, 60].contains(magnitude) ? "\(base).\(magnitude)" : base
        case .volume(let level):
            if level <= 0 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .rate: return "gauge.with.dots.needle.67percent"
        }
    }

    var caption: String? {
        switch self {
        case .play, .pause, .seek: return nil
        case .volume(let level): return level <= 0 ? String(localized: "Muted") : (level).formatted(.percent.precision(.fractionLength(0)))
        case .rate(let rate): return String(format: rate == rate.rounded() ? "%.0f×" : "%g×", rate)
        }
    }
}

struct FramePlusNotice: Equatable {
    let symbol: String
    let title: String
    let emphasized: Bool

    static let enabled = FramePlusNotice(symbol: "sparkles", title: String(localized: "Frame+ on"), emphasized: true)
    static let disabled = FramePlusNotice(symbol: "film", title: String(localized: "Frame+ off"), emphasized: false)
    static let maxFluidityOn = FramePlusNotice(symbol: "wind", title: String(localized: "Maximum Fluidity on"), emphasized: true)
    static let maxFluidityOff = FramePlusNotice(symbol: "wind", title: String(localized: "Maximum Fluidity off"), emphasized: false)
    static let reducedTo48 = FramePlusNotice(symbol: "gauge.with.dots.needle.33percent",
                                             title: String(localized: "Frame+ · 48 fps to stay smooth"), emphasized: false)
    static let superResolutionOn = FramePlusNotice(symbol: "wand.and.stars", title: String(localized: "Super Resolution on"), emphasized: true)
    static let superResolutionOff = FramePlusNotice(symbol: "wand.and.stars", title: String(localized: "Super Resolution off"), emphasized: false)
    static let superResolutionHeld = FramePlusNotice(symbol: "wand.and.stars",
                                                     title: String(localized: "Super Resolution on · paused while Frame+ keeps playback smooth"),
                                                     emphasized: false)
    static let superResolutionPaused = FramePlusNotice(symbol: "wand.and.stars",
                                                       title: String(localized: "Super Resolution paused to stay smooth"), emphasized: false)
    static let pausedByLoad = FramePlusNotice(symbol: "exclamationmark.triangle",
                                              title: String(localized: "Frame+ paused: this Mac can’t keep up"), emphasized: false)
}

/// Capa negra sobre el video: cubre la apertura y atenúa los saltos hasta que
/// llega el primer frame del destino. No toca el video ni la interpolación.
enum VideoCurtain: Equatable {
    case clear
    case opening
    case seeking

    var opacity: Double {
        switch self {
        case .clear: return 0
        case .opening: return 1
        case .seeking: return 0.5
        }
    }
}

@MainActor
final class PlayerFeedbackModel: ObservableObject {
    struct Event<Value: Equatable>: Equatable {
        let id: Int
        let value: Value
    }

    @Published private(set) var action: Event<PlayerActionFeedback>?
    @Published private(set) var notice: Event<FramePlusNotice>?
    @Published private(set) var curtain: VideoCurtain = .clear

    private var nextID = 0
    private var actionDismissal: Task<Void, Never>?
    private var noticeDismissal: Task<Void, Never>?
    private var curtainTimeout: Task<Void, Never>?

    func show(_ feedback: PlayerActionFeedback) {
        nextID += 1
        action = Event(id: nextID, value: feedback)
        actionDismissal?.cancel()
        actionDismissal = dismiss(after: 0.6) { $0.action = nil }
    }

    func show(_ value: FramePlusNotice) {
        nextID += 1
        notice = Event(id: nextID, value: value)
        noticeDismissal?.cancel()
        noticeDismissal = dismiss(after: 1.5) { $0.notice = nil }
    }

    func coverVideo(_ curtain: VideoCurtain) {
        // Un salto durante la apertura no aclara la cortina de apertura.
        guard self.curtain != .opening || curtain == .opening else { return }
        self.curtain = curtain
        curtainTimeout?.cancel()
        // Nunca queda pegada si el primer frame no llega.
        curtainTimeout = dismiss(after: 1.5) { $0.curtain = .clear }
    }

    /// Se llama por cada frame encolado; solo publica cuando hay cortina.
    func revealVideo() {
        guard curtain != .clear else { return }
        curtain = .clear
        curtainTimeout?.cancel()
    }

    private func dismiss(after seconds: Double, _ clear: @escaping (PlayerFeedbackModel) -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            clear(self)
        }
    }
}

extension PlaybackControlling {
    /// Las vistas son genéricas sobre el contrato; solo el estado real emite avisos.
    func showFeedback(_ feedback: PlayerActionFeedback) {
        (self as? RiftPlayerState)?.feedback.show(feedback)
    }
}

// MARK: - Overlay

struct VideoCurtainOverlay: View {
    @ObservedObject var model: PlayerFeedbackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.black
            .opacity(model.curtain.opacity)
            .animation(animation, value: model.curtain)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var animation: Animation? {
        switch model.curtain {
        case .opening: return nil
        case .seeking: return .easeOut(duration: 0.12)
        case .clear: return .easeOut(duration: reduceMotion ? 0.15 : 0.25)
        }
    }
}

struct PlayerFeedbackOverlay: View {
    @ObservedObject var model: PlayerFeedbackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let action = model.action {
                ActionBadge(feedback: action.value, eventID: action.id, reduceMotion: reduceMotion)
                    .id(action.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                NoticeBadge(notice: notice.value, reduceMotion: reduceMotion)
                    .id(notice.id)
                    .padding(.top, 22)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.78),
                   value: model.action?.id)
        .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.82),
                   value: model.notice?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ActionBadge: View {
    let feedback: PlayerActionFeedback
    let eventID: Int
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: feedback.symbol)
                .font(.system(size: 34, weight: .semibold))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : eventID)
                .contentTransition(.symbolEffect(.replace))
            if let caption = feedback.caption {
                Text(caption)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .frame(width: 96, height: 96)
        .background(VideoOverlayGlass(cornerRadius: 28))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

private struct NoticeBadge: View {
    let notice: FramePlusNotice
    let reduceMotion: Bool
    @State private var glow = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.emphasized ? AnyShapeStyle(RiftPalette.luminousGradient) : AnyShapeStyle(.white))
            Text(notice.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(VideoOverlayGlass(cornerRadius: 18))
        .overlay {
            if notice.emphasized, !reduceMotion {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(RiftPalette.luminousGradient, lineWidth: 1.2)
                    .opacity(glow ? 0 : 0.9)
                    .shadow(color: RiftPalette.cyan.opacity(glow ? 0 : 0.6), radius: glow ? 2 : 10)
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .onAppear {
            guard notice.emphasized, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1)) { glow = true }
        }
    }
}
