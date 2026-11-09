import Foundation

// MARK: - Interpolation Mode

/// Frame+ solo se enciende o se apaga. La cadencia (60 fps, 48 fps o sin
/// interpolar) la elige Rift según lo que mide en el Mac y según el video.
public enum InterpolationMode: CaseIterable, Sendable, RawRepresentable {
    case disabled
    case enabled

    public var rawValue: String {
        switch self {
        case .disabled: "disabled"
        case .enabled: "enabled"
        }
    }

    /// Acepta los valores guardados por versiones anteriores, que tenían varios
    /// modos ("motion2x", "motion4x", "motionAdaptive", "motion2Intense"):
    /// todos significan Frame+ encendido.
    public init?(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "enabled", "motion2x", "motion4x", "motionAdaptive", "motion2Intense": self = .enabled
        default: return nil
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

// MARK: - Super Resolution

/// User-facing preference shared by the UI contract. Rendering maps this value
/// to its implementation-specific mode without making Contracts depend on Metal.
public enum SuperResolutionPreference: String, CaseIterable, Sendable, Codable {
    case off
    case soft
    case balanced
    case strong
}

// MARK: - Visual presets

/// Valores del panel Visual. La temperatura va de −1 (fría) a +1 (cálida); la
/// vibrancia, de 0 a 1.
public struct VisualSettings: Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var temperature: Double
    public var vibrance: Double

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1,
                temperature: Double = 0, vibrance: Double = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.vibrance = vibrance
    }

    public static let neutral = VisualSettings()

    public var isNeutral: Bool { approximatelyEquals(.neutral) }

    public func approximatelyEquals(_ other: VisualSettings) -> Bool {
        abs(brightness - other.brightness) < 0.0001
            && abs(contrast - other.contrast) < 0.0001
            && abs(saturation - other.saturation) < 0.0001
            && abs(temperature - other.temperature) < 0.0001
            && abs(vibrance - other.vibrance) < 0.0001
    }
}

/// Filtros prestablecidos: combinaciones fijas de los cinco controles. No se
/// guarda cuál está activo; se deduce de los valores (si no coincide ninguno,
/// el panel muestra "Personalizado"). Valores basados en práctica de colorista:
/// contraste como curva en S, brillo en medios tonos, vibrancia en vez de
/// saturación para no forzar la piel, y Cine algo más cálido.
public enum VisualPreset: String, CaseIterable, Sendable, Codable {
    case natural, vivid, cinema, soft, bright, warm, cool, mono

    public var settings: VisualSettings {
        switch self {
        case .natural: return .neutral
        case .vivid: return VisualSettings(contrast: 1.12, vibrance: 0.30)
        case .cinema: return VisualSettings(brightness: -0.03, contrast: 1.10, saturation: 0.88, temperature: 0.15)
        case .soft: return VisualSettings(brightness: 0.03, contrast: 0.88, saturation: 0.92)
        case .bright: return VisualSettings(brightness: 0.12, saturation: 1.05)
        case .warm: return VisualSettings(saturation: 1.05, temperature: 0.40)
        case .cool: return VisualSettings(temperature: -0.40)
        case .mono: return VisualSettings(contrast: 1.15, saturation: 0)
        }
    }

    public static func matching(_ settings: VisualSettings) -> VisualPreset? {
        allCases.first { $0.settings.approximatelyEquals(settings) }
    }
}
