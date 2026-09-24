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
    /// La validación bidireccional evita deformaciones en oclusiones, pero puede
    /// descartar un par completo y repetir los frames fuente. Los perfiles de
    /// fluidez la omiten: conservan el guard de campos de movimiento claramente
    /// rotos y priorizan que el movimiento siga siendo temporalmente continuo.
    public let usesBidirectionalSafetyCheck: Bool
    /// El guard de campos catastróficos evita warps extremos. El perfil por
    /// defecto repite el frame fuente; los perfiles fluidos lo combinan con una
    /// mezcla temporal sin vectores para no reducir la cadencia.
    public let usesCatastrophicSafetyCheck: Bool
    /// Cuando el guard de campo catastrófico detecta movimiento no fiable,
    /// atenúa sus vectores en vez de repetir un frame fuente. Solo corresponde
    /// a los perfiles fluidos y conserva una transición espacial visible.
    public let usesAttenuatedCatastrophicSafetyBlend: Bool
    /// Detecta efectos que cambian de forma o luminancia sin una correspondencia
    /// espacial fiable (destellos, rayos, partículas). Es un muestreo ligero del
    /// residuo tras compensar movimiento; cuando una zona extensa es incompatible
    /// usa una mezcla temporal sin vectores en vez del warp deformado.
    public let usesUnmatchableEffectSafetyCheck: Bool

    public init(workWidth: Int = 1152,
                workHeight: Int = 480,
                blockSize: Int = 8,
                lambdaPx: UInt32 = 1,
                subpel: Bool = true,
                temporalGatePx: UInt32 = 2,
                usesBidirectionalSafetyCheck: Bool = true,
                usesCatastrophicSafetyCheck: Bool = true,
                usesAttenuatedCatastrophicSafetyBlend: Bool = false,
                usesUnmatchableEffectSafetyCheck: Bool = false) {
        self.workWidth = workWidth
        self.workHeight = workHeight
        self.blockSize = blockSize
        self.lambdaPx = lambdaPx
        self.subpel = subpel
        self.temporalGatePx = temporalGatePx
        self.usesBidirectionalSafetyCheck = usesBidirectionalSafetyCheck
        self.usesCatastrophicSafetyCheck = usesCatastrophicSafetyCheck
        self.usesAttenuatedCatastrophicSafetyBlend = usesAttenuatedCatastrophicSafetyBlend
        self.usesUnmatchableEffectSafetyCheck = usesUnmatchableEffectSafetyCheck
    }

    public static let `default` = InterpolationConfig()
    public static let fluid = InterpolationConfig(
        usesBidirectionalSafetyCheck: false,
        usesCatastrophicSafetyCheck: true,
        usesAttenuatedCatastrophicSafetyBlend: false,
        usesUnmatchableEffectSafetyCheck: false
    )
    /// Perfil de máxima calidad para equipos que sí sostienen el coste real.
    /// Conserva la política de fluidez y duplica la densidad espacial práctica
    /// del campo frente al work-plane base sin llegar al coste de 4K completo.
    /// La UI lo degrada en vivo a `fluid` si el par completo no cabe a 60 Hz.
    public static let fluidHighQuality = InterpolationConfig(
        workWidth: 1536,
        workHeight: 640,
        usesBidirectionalSafetyCheck: false,
        usesCatastrophicSafetyCheck: true,
        usesAttenuatedCatastrophicSafetyBlend: false,
        usesUnmatchableEffectSafetyCheck: false
    )
}
