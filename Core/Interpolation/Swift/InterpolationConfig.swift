import Foundation

// MARK: - InterpolationConfig
//
// Parámetros del motor MCFI clásico. El MVP usa work plane fijo a 480p (validado
// en MVProbe sobre el archivo de prueba); los MVs se computan a esa resolución
// y el warp re-ensambla el frame a la resolución nativa del video (CVPixelBuffer
// de I0). Ver AGENTS.md sección 'Rango de hardware soportado' — la auto-calibración
// del work plane por chip queda pendiente como limitación conocida.

public struct InterpolationConfig: Sendable {
    public let workWidth: Int
    public let workHeight: Int
    public let blockSize: Int
    public let lambdaPx: UInt32
    public let subpel: Bool
    /// Umbral de la EMA temporal gated (en px): por bloque, si el cambio de MV
    /// entre pares consecutivos no supera este valor, se mezcla hacia el MV del
    /// par anterior (α=0.5). Cambios mayores pasan sin tocar (movimiento real).
    /// 0 desactiva el pase. Ver `mvTemporalEMA` y `MotionSearchEngine`.
    public let temporalGatePx: UInt32

    public init(workWidth: Int = 1152,
                workHeight: Int = 480,
                blockSize: Int = 8,
                lambdaPx: UInt32 = 1,
                subpel: Bool = true,
                temporalGatePx: UInt32 = 2) {
        self.workWidth = workWidth
        self.workHeight = workHeight
        self.blockSize = blockSize
        self.lambdaPx = lambdaPx
        self.subpel = subpel
        self.temporalGatePx = temporalGatePx
    }

    public static let `default` = InterpolationConfig()
}
