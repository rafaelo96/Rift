import Foundation
import Metal
import CoreVideo

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
                gateL0: true
            )
        } catch {
            throw Error.engineInitFailed("\(error)")
        }

        do {
            self.warp = try WarpEngine(device: device)
        } catch {
            throw Error.warpInitFailed("\(error)")
        }
    }

    /// Genera un frame interpolado entre I0 (t=0) e I1 (t=1) al instante t∈(0,1).
    /// Conserva los attachments HDR (BT.2020/PQ) de I0 en el resultado vía
    /// `WarpEngine.interpolatePixelBuffer`. Retorna nil si el par es inválido o
    /// si ocurre un fallo en el pipeline.
    public func interpolate(I0: CVPixelBuffer, I1: CVPixelBuffer, t: Float) -> CVPixelBuffer? {
        guard let luma0 = scaledLuma(I0),
              let luma1 = scaledLuma(I1) else { return nil }

        // ME: pyramidal block matching, half-pel MVs al nivel L0.
        let _ = me.runPair(cur: luma0, ref: luma1)
        let mvField = me.downloadMV(level: 0, smoothed: true)
        guard !mvField.isEmpty else { return nil }

        let g = me.grids[0]
        return warp.interpolatePixelBuffer(
            I0: I0, I1: I1,
            mv: mvField,
            gridW: g.w, gridH: g.h,
            blockSize: config.blockSize,
            t: t,
            occThresh: 1.0
        )
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
        let is10Bit = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        var src = [UInt16](repeating: 0, count: sw * sh)
        if is10Bit {
            for y in 0..<sh {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt16.self)
                for x in 0..<sw { src[y * sw + x] = row[x] >> 6 }
            }
        } else {
            for y in 0..<sh {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<sw { src[y * sw + x] = UInt16(row[x]) << 8 }
            }
        }

        // Nearest-neighbor downscale a (workWidth, workHeight).
        let dw = config.workWidth
        let dh = config.workHeight
        var dst = Data(count: dw * dh * MemoryLayout<UInt16>.stride)
        dst.withUnsafeMutableBytes { dstRaw in
            let dst16 = dstRaw.bindMemory(to: UInt16.self).baseAddress!
            for y in 0..<dh {
                let sy = min(sh - 1, y * sh / dh)
                for x in 0..<dw {
                    let sx = min(sw - 1, x * sw / dw)
                    dst16[y * dw + x] = src[sy * sw + sx]
                }
            }
        }
        return dst
    }
}
