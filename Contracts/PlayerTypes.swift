import Foundation

// MARK: - Interpolation Mode

public enum InterpolationMode: String, CaseIterable, Sendable {
    case disabled
    case rife2x
    case rife4x
    case rifeAdaptive
    case motion2Intense

    public var displayName: String {
        switch self {
        case .disabled: "Off"
        case .rife2x: "RIFE 2x"
        case .rife4x: "RIFE 4x"
        case .rifeAdaptive: "Adaptive"
        case .motion2Intense: "Motion² Intenso"
        }
    }
}

// MARK: - Media Track

public struct MediaTrack: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case video
        case audio
        case subtitle
    }

    public let id: String
    public let kind: Kind
    public let index: Int
    public let label: String
    public let languageCode: String?

    public init(id: String, kind: MediaTrack.Kind, index: Int, label: String, languageCode: String?) {
        self.id = id
        self.kind = kind
        self.index = index
        self.label = label
        self.languageCode = languageCode
    }
}

// MARK: - Audio Track
//
// Pista de audio lista para la UI (selector de Audio). En la referencia vive
// anidada en `PlayerState.AudioTrack`; aquí se expone como tipo compartido
// para que UI/ y Core/ (futuro) la usen sin acoplarse.

public struct AudioTrack: Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let language: String?

    public init(id: Int, label: String, language: String?) {
        self.id = id
        self.label = label
        self.language = language
    }
}

// MARK: - FPS Mode

public enum FPSMode: String, CaseIterable, Sendable {
    case native = "Native FPS"
    case flux = "Flux"

    public var next: FPSMode {
        switch self {
        case .native: .flux
        case .flux: .native
        }
    }

    public var isActive: Bool {
        self == .flux
    }

    public func renderFramesPerSecond(sourceFrameRate: Double?) -> Int {
        switch self {
        case .native:
            guard let sourceFrameRate = sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 else { return 60 }
            return max(1, min(240, Int(sourceFrameRate.rounded())))
        case .flux:
            return 60
        }
    }
}