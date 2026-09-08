import Foundation
import Metal
import Accelerate
import CoreVideo

/// Resultado de una llamada a `interpolateWithTimings`: el buffer interpolado
/// (preservando attachments HDR del I0) más los tiempos medidos en GPU del ME
/// y del warp. Los tiempos son wall-clock del proceso Swift (cubren host +
/// comando Metal + GPU), no son GPU-pure.
public struct InterpolationResult {
    public let pixelBuffer: CVPixelBuffer?
    public let meMS: Double
    public let warpMS: Double
    public let upscaleMS: Double

    public init(pixelBuffer: CVPixelBuffer?, meMS: Double, warpMS: Double, upscaleMS: Double = 0) {
        self.pixelBuffer = pixelBuffer
        self.meMS = meMS
        self.warpMS = warpMS
        self.upscaleMS = upscaleMS
    }
}

/// Resultado por-par de `interpolatePair`: un buffer interpolado por cada `t`
/// pedido (en el mismo orden que `tValues`) + tiempos al nivel de par.
public struct InterpolationPairResult {
    public let pixelBuffers: [CVPixelBuffer]
    public let meMS: Double
    public let warpMS: Double
    public let upscaleMS: Double

    public init(pixelBuffers: [CVPixelBuffer], meMS: Double, warpMS: Double, upscaleMS: Double = 0) {
        self.pixelBuffers = pixelBuffers
        self.meMS = meMS
        self.warpMS = warpMS
        self.upscaleMS = upscaleMS
    }
}

// MARK: - MotionCompensator
//
// Punto de entrada público del módulo Interpolation. Envuelve MotionSearchEngine
// (estimación de movimiento block-matching piramidal en Metal) y WarpEngine
// (backward warp + occlusion blend en Metal). El par de CVPixelBuffer de entrada
// se reduce a un work plane (config.workWidth × config.workHeight) antes del ME,
// el warp opera a esa resolución, y el resultado se re-ensambla en un CVPixelBuffer
// del mismo tamaño y formato que I0 (preservando attachments HDR del I0 vía
// WarpEngine.interpolatePixelBuffer).
//
// Stateless por par: cada llamada a `interpolate(I0:, I1:, t:)` es autocontenida.
// Los recursos Metal (device, queue, texturas, MV buffers) se reservan una vez en
// `init` y se reusan entre pares. Sin archivos derivados en disco — todo el flujo
// vive en memoria sobre CVPixelBuffer IOSurface-backed del decoder.

public final class MotionCompensator {

    public enum Error: Swift.Error, CustomStringConvertible {
        case metalDeviceUnavailable
        case engineInitFailed(String)
        case warpInitFailed(String)
        case pixelBufferFormatUnsupported

        public var description: String {
            switch self {
            case .metalDeviceUnavailable: return "MotionCompensator: no Metal device"
            case .engineInitFailed(let m): return "MotionCompensator: ME init failed — \(m)"
            case .warpInitFailed(let m): return "MotionCompensator: warp init failed — \(m)"
            case .pixelBufferFormatUnsupported: return "MotionCompensator: pixel buffer format not supported"
            }
        }
    }

    public let config: InterpolationConfig

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let me: MotionSearchEngine
    private let warp: WarpEngine

    // Texturas L0 reusables: una por slot (I0, I1). Las redimensionamos si el
    // tamaño del par cambia (no debería — siempre llega del mismo video).
    private var texI0: MTLTexture?
    private var texI1: MTLTexture?

    // Scratch reusable para las rutinas vDSP del gate estático (flotan una vez
    // en init; el work-plane tiene tamaño fijo por config). Evita malloc/free
    // por par en el camino caliente. Tamaño = workWidth*workHeight.
    private var vdspA: [Float] = []
    private var vdspB: [Float] = []
    private var vdspC: [Float] = []
    private var vdspU8: [UInt8] = []
    private var vdspHist = [vImagePixelCount](repeating: 0, count: 256)

    public init(config: InterpolationConfig = .default) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.metalDeviceUnavailable
        }
        self.device = device
        self.queue = queue
        self.config = config
        let n = config.workWidth * config.workHeight
        vdspA = [Float](repeating: 0, count: n)
        vdspB = [Float](repeating: 0, count: n)
        vdspC = [Float](repeating: 0, count: n)
        vdspU8 = [UInt8](repeating: 0, count: n)

        // Piramide 3-niveles para ME (coarse-to-fine). Mismos params que MVProbe
        // (validado contra archivo de referencia): L0 full work plane, L1/L2/L3
        // 2x downscale cada uno, search half-pel crece por nivel.
        let spec: [LevelSpec] = [
            LevelSpec(width: config.workWidth, height: config.workHeight,
                      blockSize: config.blockSize, searchHalfPel: 8,
                      halfPelRefine: config.subpel, inheritFactor: 4),
            LevelSpec(width: config.workWidth / 2, height: config.workHeight / 2,
                      blockSize: 16, searchHalfPel: 16, halfPelRefine: false, inheritFactor: 2),
            LevelSpec(width: config.workWidth / 4, height: config.workHeight / 4,
                      blockSize: 16, searchHalfPel: 32, halfPelRefine: false, inheritFactor: 2),
            LevelSpec(width: config.workWidth / 8, height: config.workHeight / 8,
                      blockSize: 16, searchHalfPel: 32, halfPelRefine: false, inheritFactor: 1),
        ]

        do {
            self.me = try MotionSearchEngine(
                msl: motionShadersMSL,
                spec: spec,
                lambdaPx: config.lambdaPx,
                smoothL0: true,
                gateL0: true,
                temporalGatePx: config.temporalGatePx
            )
        } catch {
            throw Error.engineInitFailed("\(error)")
        }

        do {
            self.warp = try WarpEngine(msl: warpShadersMSL)
        } catch {
            throw Error.warpInitFailed("\(error)")
        }
    }

    /// Limpia el estado temporal de la EMA de MVs (el par siguiente se emite sin
    /// blending). Debe llamarse en seek, pause→resume, flush y loadVideo para no
    /// arrastrar historia de jitter a través de una discontinuidad temporal.
    public func resetTemporalState() {
        me.resetTemporalState()
    }

    /// Genera un frame interpolado entre I0 (t=0) e I1 (t=1) al instante t∈(0,1).
    /// Conserva los attachments HDR (BT.2020/PQ) de I0 en el resultado vía
    /// `WarpEngine.interpolatePixelBuffer`. Retorna nil si el par es inválido o
    /// si ocurre un fallo en el pipeline.
    public func interpolate(I0: CVPixelBuffer, I1: CVPixelBuffer, t: Float) -> CVPixelBuffer? {
        interpolateWithTimings(I0: I0, I1: I1, t: t).pixelBuffer
    }

    /// Variante de `interpolate` que además reporta los tiempos medidos en GPU
    /// del ME (motion estimation, jerarquía piramidal completa) y del warp
    /// (backward-warp + occlusion blend + re-ensamblado del CVPixelBuffer con
    /// attachments HDR). Útil para instrumentación en producción — el caller
    /// puede loguear avg/p99 y verificar que cabe en el presupuesto de tiempo
    /// real del frame siguiente sin generalizar entre chips.
    /// Fast-path de interpolación por-par (Fase B): calcula scaledLuma(I0),
    /// scaledLuma(I1) y el ME (runPair) UNA sola vez por par y genera un frame
    /// interpolado por cada `t` en `tValues` reusando ese mismo resultado — solo
    /// warp + upscale + CbCr + HDR se repiten por `t`. Para la cadencia 3:2 de
    /// .interpolated60 (tValues=[1/3,2/3]) esto elimina el ME+luma duplicado del
    /// camino viejo (llamaba interpolateWithTimings dos veces por par). Los
    /// buffers de salida vienen del pool reusable de WarpEngine.
    /// Devuelve buffers vacíos y MS 0 si el par es inválido.
    public func interpolatePair(I0: CVPixelBuffer, I1: CVPixelBuffer, tValues: [Float]) -> InterpolationPairResult {
        guard !tValues.isEmpty else { return InterpolationPairResult(pixelBuffers: [], meMS: 0, warpMS: 0) }

        guard let luma0 = scaledLuma(I0), let luma1 = scaledLuma(I1) else {
            return InterpolationPairResult(pixelBuffers: [], meMS: 0, warpMS: 0)
        }

        // Fast-path estático: si el par no cambió (ruido), el frame intermedio
        // correcto ES el input — devolver I0 directo evita el blur del
        // round-trip a work-plane (los interpolados salían más suaves que los
        // nativos y el logo "se veía distinto" / pulsaba a 24Hz). Pixel-perfect,
        // costo ~1ms (MAD + textura en host) y se ahorra el ME+warp del par.
        // Ver isStaticPair: gate conservador de dos señales (el MAD global solo
        // comía movimiento tenue). Un falso positivo solo repite I0 en
        // contenido casi-estático (invisible); un falso negativo es el camino
        // normal (status quo). El estado EMA no necesita reset: contenido
        // estático lo mantiene en cero de todos modos.
        if isStaticPair(luma0, luma1) {
            return InterpolationPairResult(pixelBuffers: tValues.map { _ in I0 },
                                           meMS: 0, warpMS: 0, upscaleMS: 0)
        }

        let meStart = DispatchTime.now().uptimeNanoseconds
        let pairTimes = me.runPair(cur: luma0, ref: luma1)
        let meMS = Double(DispatchTime.now().uptimeNanoseconds - meStart) / 1_000_000.0

        let mvField = me.downloadMV(level: 0, smoothed: true)
        guard !mvField.isEmpty else {
            return InterpolationPairResult(pixelBuffers: [], meMS: meMS, warpMS: 0)
        }

        let g = me.grids[0]
        let (buffers, warpTotal, upscaleTotal) = warp.interpolatePixelBufferPair(
            I0: I0, I1: I1,
            luma0: luma0, luma1: luma1,
            workWidth: config.workWidth, workHeight: config.workHeight,
            mv: mvField,
            gridW: g.w, gridH: g.h,
            blockSize: config.blockSize,
            tValues: tValues,
            occThresh: 1.0
        )
        _ = pairTimes
        return InterpolationPairResult(pixelBuffers: buffers, meMS: meMS, warpMS: warpTotal, upscaleMS: upscaleTotal)
    }

    /// Interpola un solo frame (camino clásico, una llamada por `t`). Se conserva
    /// para compatibilidad/determinismo; el pipeline usa `interpolatePair`.
    public func interpolateWithTimings(I0: CVPixelBuffer, I1: CVPixelBuffer, t: Float) -> InterpolationResult {
        guard let luma0 = scaledLuma(I0),
              let luma1 = scaledLuma(I1) else {
            return InterpolationResult(pixelBuffer: nil, meMS: 0, warpMS: 0)
        }

        // Fast-path estático (ver interpolatePair): par sin cambio → I0 directo.
        if isStaticPair(luma0, luma1) {
            return InterpolationResult(pixelBuffer: I0, meMS: 0, warpMS: 0, upscaleMS: 0)
        }

        // ME: pyramidal block matching, half-pel MVs al nivel L0.
        let meStart = DispatchTime.now().uptimeNanoseconds
        let pairTimes = me.runPair(cur: luma0, ref: luma1)
        let meMS = Double(DispatchTime.now().uptimeNanoseconds - meStart) / 1_000_000.0

        let mvField = me.downloadMV(level: 0, smoothed: true)
        guard !mvField.isEmpty else {
            return InterpolationResult(pixelBuffer: nil, meMS: meMS, warpMS: 0)
        }

        let g = me.grids[0]
        let (pb, gpuWarpMS, upscaleMS) = warp.interpolatePixelBuffer(
            I0: I0, I1: I1,
            luma0: luma0, luma1: luma1,
            workWidth: config.workWidth, workHeight: config.workHeight,
            mv: mvField,
            gridW: g.w, gridH: g.h,
            blockSize: config.blockSize,
            t: t,
            occThresh: 1.0
        )
        _ = pairTimes
        return InterpolationResult(pixelBuffer: pb, meMS: meMS, warpMS: gpuWarpMS, upscaleMS: upscaleMS)
    }

    // Diferencia media absoluta entre dos lumas de work-plane (Data de UInt16,
    // mismo layout que produce scaledLuma). En unidades del work-plane (0..1023
    // en 10-bit). Cadena vDSP (precompilada: ~0.3ms en debug vs ~38ms del loop
    // Swift). La suma en Float pierde precisión entera muy por debajo del
    // umbral del gate (6.0), irrelevante aquí.
    private func workMAD(_ a: Data, _ b: Data) -> Double {
        guard a.count == b.count, a.count % 2 == 0 else { return .infinity }
        let n = a.count / 2
        guard vdspA.count >= n, vdspB.count >= n, vdspC.count >= n else { return .infinity }
        var sum: Float = 0
        a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                vdspA.withUnsafeMutableBufferPointer { fa in
                    vdspB.withUnsafeMutableBufferPointer { fb in
                        vdspC.withUnsafeMutableBufferPointer { fc in
                            vDSP_vfltu16(ra.bindMemory(to: UInt16.self).baseAddress!, 1,
                                         fa.baseAddress!, 1, vDSP_Length(n))
                            vDSP_vfltu16(rb.bindMemory(to: UInt16.self).baseAddress!, 1,
                                         fb.baseAddress!, 1, vDSP_Length(n))
                            vDSP_vsub(fb.baseAddress!, 1, fa.baseAddress!, 1,
                                      fc.baseAddress!, 1, vDSP_Length(n))
                            vDSP_vabs(fc.baseAddress!, 1, fc.baseAddress!, 1, vDSP_Length(n))
                            vDSP_sve(fc.baseAddress!, 1, &sum, vDSP_Length(n))
                        }
                    }
                }
            }
        }
        return Double(sum) / Double(n)
    }

    // Fracción de píxeles con textura (gradiente local en cruz > `threshold`,
    // unidades del work-plane) en el interior del frame. Si el layout no cuadra
    // devuelve 1.0 para NO skipear (dirección segura).
    //
    // Cadena vDSP+vImage (precompilada: ~3.6ms en debug vs ~62ms del loop
    // Swift), con IGUALDAD EXACTA al loop de referencia (verificado): shifts
    // por memmove (correctos en todo píxel contado; bordes basura), bordes
    // anulados a 0 (nunca contados), cuantización (g+3)>>2 que parte el bin
    // justo en el borde 24/25, e histograma Planar8: contados = N - bins[0..6].
    private func texturedFraction(_ a: Data, width: Int, height: Int, threshold: Int) -> Double {
        guard a.count == width * height * 2, threshold == 24 else { return 1.0 }
        let n = width * height
        let w = width, h = height
        guard vdspA.count >= n, vdspB.count >= n, vdspC.count >= n, vdspU8.count >= n else { return 1.0 }
        var count = 0
        a.withUnsafeBytes { raw in
            vdspA.withUnsafeMutableBufferPointer { fa in
                vdspB.withUnsafeMutableBufferPointer { fb in
                    vdspC.withUnsafeMutableBufferPointer { fc in
                        vdspU8.withUnsafeMutableBufferPointer { u8 in
                            let F = fa.baseAddress!, S = fb.baseAddress!, G = fc.baseAddress!
                            vDSP_vfltu16(raw.bindMemory(to: UInt16.self).baseAddress!, 1,
                                         F, 1, vDSP_Length(n))
                            let B = 4 * n
                            // d1=|F-FL| con FL[i]=F[i-1]
                            memmove(S, F, B - 4)
                            vDSP_vsub(S, 1, F, 1, G, 1, vDSP_Length(n))
                            vDSP_vabs(G, 1, G, 1, vDSP_Length(n))
                            // d2=|FR-F| acumulado
                            memmove(S, F + 1, B - 4)
                            vDSP_vsub(F, 1, S, 1, S, 1, vDSP_Length(n))
                            vDSP_vabs(S, 1, S, 1, vDSP_Length(n))
                            vDSP_vadd(G, 1, S, 1, G, 1, vDSP_Length(n))
                            // d3=|F-FU| acumulado
                            memmove(S, F, B - 4 * w)
                            vDSP_vsub(S, 1, F, 1, S, 1, vDSP_Length(n))
                            vDSP_vabs(S, 1, S, 1, vDSP_Length(n))
                            vDSP_vadd(G, 1, S, 1, G, 1, vDSP_Length(n))
                            // d4=|FD-F| acumulado
                            memmove(S, F + w, B - 4 * w)
                            vDSP_vsub(F, 1, S, 1, S, 1, vDSP_Length(n))
                            vDSP_vabs(S, 1, S, 1, vDSP_Length(n))
                            vDSP_vadd(G, 1, S, 1, G, 1, vDSP_Length(n))
                            // Anular bordes (filas 0,H-1 y columnas 0,W-1).
                            for x in 0..<w { G[x] = 0; G[(h - 1) * w + x] = 0 }
                            for y in 0..<h { G[y * w] = 0; G[y * w + w - 1] = 0 }
                            // (g+3)>>2: g=24→bin6, g≥25→bin≥7. Contar N-bins[0..6].
                            var three: Float = 3.0, quarter: Float = 0.25
                            vDSP_vsadd(G, 1, &three, G, 1, vDSP_Length(n))
                            vDSP_vsmul(G, 1, &quarter, G, 1, vDSP_Length(n))
                            vDSP_vfixu8(G, 1, u8.baseAddress!, 1, vDSP_Length(n))
                            var srcBuf = vImage_Buffer(data: u8.baseAddress!,
                                                       height: vImagePixelCount(h),
                                                       width: vImagePixelCount(w),
                                                       rowBytes: w)
                            for b in 0..<256 { vdspHist[b] = 0 }
                            vdspHist.withUnsafeMutableBufferPointer { histBuf in
                                vImageHistogramCalculation_Planar8(&srcBuf, histBuf.baseAddress!, vImage_Flags(kvImageNoFlags))
                            }
                            var lo: vImagePixelCount = 0
                            for b in 0...6 { lo += vdspHist[b] }
                            count = n - Int(lo)
                        }
                    }
                }
            }
        }
        return Double(count) / Double(n)
    }

    // Gate del fast-path estático (conservador, dos señales): el MAD global
    // solo come movimiento tenue/oscuro con desplazamiento real (medido:
    // escenas 30%/80% con 21-42% de bloques en movimiento daban MAD 5-6).
    // Se exige ADEMÁS fracción con textura < 6% (grad>24): el logo estático
    // da 3.3%; las escenas con movimiento medido dan 9-20%. Un falso positivo
    // es imposible en el movimiento medido; un falso negativo es status quo.
    private func isStaticPair(_ luma0: Data, _ luma1: Data) -> Bool {
        guard workMAD(luma0, luma1) < 6.0 else { return false }
        return texturedFraction(luma0, width: config.workWidth, height: config.workHeight, threshold: 24) < 0.06
    }

    // MARK: - Luma extraction + downscale (host)
    //
    // Extrae el plano 0 (luma) del CVPixelBuffer de entrada y lo baja a
    // (workWidth × workHeight) en UInt16. Soporta el formato planar BiPlanar
    // 10-bit usado por VTDecoder (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    // / 'x420'). Para 8-bit (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    // se preserva la escala histórica (value<<8).
    //
    // Downscale con vImage (precompilado: rápido en debug Y release) en vez de
    // loops Swift — en debug los loops costaban ~900ms/par y mataban el
    // presupuesto. Mismas flags que el harness de medición
    // (kvImageHighQualityResampling | kvImageDoNotTile) para que producción y
    // medición vean exactamente el mismo work-plane. Fase de muestreo centrada
    // como `upscaleLuma` (verificado empíricamente: sin offset sistemático en
    // el round-trip). Tras escalar, normalización a la escala del work-plane
    // (>>6 en 10-bit por linealidad: escalar-crudo-y-shiftear == shiftear-y-
    // escalar salvo redondeo ≤1 LSB post-shift, irrelevante para ME).

    private func scaledLuma(_ buffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let sw = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sh = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }

        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        let is10Bit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        let dw = config.workWidth
        let dh = config.workHeight
        var dst = Data(count: dw * dh * MemoryLayout<UInt16>.stride)
        if is10Bit {
            let err: vImage_Error = dst.withUnsafeMutableBytes { dstRaw in
                guard let dstPtr = dstRaw.bindMemory(to: UInt16.self).baseAddress else {
                    return vImage_Error(kvImageInvalidParameter)
                }
                var srcBuf = vImage_Buffer(data: base,
                                           height: vImagePixelCount(sh),
                                           width: vImagePixelCount(sw),
                                           rowBytes: bpr)
                var dstBuf = vImage_Buffer(data: dstPtr,
                                           height: vImagePixelCount(dh),
                                           width: vImagePixelCount(dw),
                                           rowBytes: dw * MemoryLayout<UInt16>.stride)
                return vImageScale_Planar16U(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile))
            }
            guard err == kvImageNoError else { return nil }
            // Normalizar 10-bit (bits altos) a la escala del work-plane con
            // vDSP (precompilado; el loop Swift costaba ~30ms en debug).
            // /64 y *256 son potencias de 2 exactas en Float32 y vfixu16
            // trunca: bit-idéntico a >>6 / <<8 del camino anterior.
            var div: Float = 1.0 / 64.0
            dst.withUnsafeMutableBytes { dstRaw in
                vdspA.withUnsafeMutableBufferPointer { fa in
                    vDSP_vfltu16(dstRaw.bindMemory(to: UInt16.self).baseAddress!, 1,
                                 fa.baseAddress!, 1, vDSP_Length(dw * dh))
                    vDSP_vsmul(fa.baseAddress!, 1, &div,
                               fa.baseAddress!, 1, vDSP_Length(dw * dh))
                    vDSP_vfixu16(fa.baseAddress!, 1,
                                 dstRaw.bindMemory(to: UInt16.self).baseAddress!, 1,
                                 vDSP_Length(dw * dh))
                }
            }
            return dst
        } else {
            var tmp = [UInt8](repeating: 0, count: dw * dh)
            let err: vImage_Error = tmp.withUnsafeMutableBufferPointer { tmpBuf in
                guard let tmpPtr = tmpBuf.baseAddress else {
                    return vImage_Error(kvImageInvalidParameter)
                }
                var srcBuf = vImage_Buffer(data: base,
                                           height: vImagePixelCount(sh),
                                           width: vImagePixelCount(sw),
                                           rowBytes: bpr)
                var dstBuf = vImage_Buffer(data: tmpPtr,
                                           height: vImagePixelCount(dh),
                                           width: vImagePixelCount(dw),
                                           rowBytes: dw)
                return vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile))
            }
            guard err == kvImageNoError else { return nil }
            // 8-bit: loop Swift (552k ops simples; este path es secundario —
            // el contenido HDR de referencia es 10-bit).
            dst.withUnsafeMutableBytes { dstRaw in
                let p = dstRaw.bindMemory(to: UInt16.self).baseAddress!
                for i in 0..<(dw * dh) { p[i] = UInt16(tmp[i]) << 8 }
            }
            return dst
        }
    }
}
