import Foundation
import Metal
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

    public init(config: InterpolationConfig = .default) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.metalDeviceUnavailable
        }
        self.device = device
        self.queue = queue
        self.config = config

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

    // MARK: - Luma extraction + downscale (host)
    //
    // Extrae el plano 0 (luma) del CVPixelBuffer de entrada y lo baja a
    // (workWidth × workHeight) en UInt16. Soporta el formato planar BiPlanar
    // 10-bit usado por VTDecoder (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    // / 'x420'). Para 8-bit (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    // se hace upscale a 16-bit con left-shift 8.
    //
    // Estrategia de downscale: nearest-neighbor por bloque. Suficiente para MVP
    // (los MVs son robustos a aliasing leve y el warp luego opera a 480p). Si se
    // observan artefactos en bordes de movimiento, cambiar a bilinear (unas
    // pocas líneas más). Documentado en AGENTS.md como limitación conocida.

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

        // 1. Extraer luma de forma veloz usando UnsafeMutablePointer para evitar bounds-checking en Debug
        var src = [UInt16](repeating: 0, count: sw * sh)
        src.withUnsafeMutableBufferPointer { srcBuf in
            guard let dstPtr = srcBuf.baseAddress else { return }
            if is10Bit {
                for y in 0..<sh {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt16.self)
                    let dstRow = dstPtr.advanced(by: y * sw)
                    for x in 0..<sw { dstRow[x] = row[x] >> 6 }
                }
            } else {
                for y in 0..<sh {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    let dstRow = dstPtr.advanced(by: y * sw)
                    for x in 0..<sw { dstRow[x] = UInt16(row[x]) << 8 }
                }
            }
        }

        // 2. Downscale bilinear con fase centrada, consistente con `upscaleLuma`
        // (kernel MSL): `p = (o + 0.5) * src/dst - 0.5`. El nearest anterior, aun
        // centrado, dejaba un sesgo sistematico de ~0.65px en el round-trip porque
        // cuantizaba cada texel del work-plane al entero mas cercano y el upscale
        // bilinear ya no podia reconstruir la fase continua. Con bilinear en ambos
        // lados, el round-trip full-res (downscale → warp quieto → upscale) es la
        // identidad en coordenadas continuas: el contenido estatico deja de
        // "bailar". Costo: ~4 lecturas + interpolacion por pixel de destino.
        let dw = config.workWidth
        let dh = config.workHeight
        let xScale = Float(sw) / Float(dw)
        let yScale = Float(sh) / Float(dh)
        var dst = Data(count: dw * dh * MemoryLayout<UInt16>.stride)
        dst.withUnsafeMutableBytes { dstRaw in
            let dst16 = dstRaw.bindMemory(to: UInt16.self).baseAddress!
            src.withUnsafeBufferPointer { srcBuf in
                let srcPtr = srcBuf.baseAddress!
                for y in 0..<dh {
                    let fyc = min(max((Float(y) + 0.5) * yScale - 0.5, 0), Float(sh - 1))
                    let y0 = min(Int(fyc), sh - 2)
                    let wy = fyc - Float(y0)
                    let row0 = srcPtr.advanced(by: y0 * sw)
                    let row1 = srcPtr.advanced(by: (y0 + 1) * sw)
                    let dstRow = dst16.advanced(by: y * dw)
                    for x in 0..<dw {
                        let fxc = min(max((Float(x) + 0.5) * xScale - 0.5, 0), Float(sw - 1))
                        let x0 = min(Int(fxc), sw - 2)
                        let wx = fxc - Float(x0)
                        let s00 = Float(row0[x0])
                        let s10 = Float(row0[x0 + 1])
                        let s01 = Float(row1[x0])
                        let s11 = Float(row1[x0 + 1])
                        let top = s00 + (s10 - s00) * wx
                        let bot = s01 + (s11 - s01) * wx
                        dstRow[x] = UInt16(top + (bot - top) * wy + 0.5)
                    }
                }
            }
        }
        return dst
    }
}
