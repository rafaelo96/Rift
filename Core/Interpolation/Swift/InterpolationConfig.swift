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

    public init(workWidth: Int = 1152,
                workHeight: Int = 480,
                blockSize: Int = 8,
                lambdaPx: UInt32 = 1,
                subpel: Bool = true) {
        self.workWidth = workWidth
        self.workHeight = workHeight
        self.blockSize = blockSize
        self.lambdaPx = lambdaPx
        self.subpel = subpel
    }

    public static let `default` = InterpolationConfig()
}
