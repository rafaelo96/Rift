import Contracts
import Foundation

extension VisualPreset {
    /// Nombre visible del filtro en el panel Visual.
    var title: String {
        switch self {
        case .natural: return String(localized: "Natural")
        case .vivid: return String(localized: "Vivid")
        case .cinema: return String(localized: "Cinema")
        case .soft: return String(localized: "Soft")
        case .bright: return String(localized: "Bright")
        case .warm: return String(localized: "Warm")
        case .cool: return String(localized: "Cool")
        case .mono: return String(localized: "B&W")
        }
    }
}
