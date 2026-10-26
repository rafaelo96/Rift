import Foundation
import CoreVideo

// MARK: - RepeatedFrameDetector
//
// Animación en "dos": un frame fuente repite al anterior (mismo dibujo, solo ruido
// de compresión). Interpolar entre dos frames idénticos no produce movimiento y
// el siguiente par trae el salto doble: tirón a 12 fps en la salida a 60.
//
// Medida (calibrada offline, MVProbe MV_CUT_FEATURES=1 / MV_DEDUP_SIM=1, Avatar
// 2026 4K HDR, 2878 pares): luma promediada en celdas de 3×3, diferencia media
// por bloques de 16×16 celdas (~48×48 px nativos), máximo sobre bloques. Es
// bimodal: ruido 0.25–4, movimiento ≥ 8 (escala 0…1023), 6 pares entre 4 y 8.
// Repetido si el máximo < 4. Un solo bloque con movimiento real basta para
// que el par NO sea repetido (labios, parpadeos).

public enum RepeatedFrameDetector {
    /// Máxima diferencia media por bloque (luma 0…1023) para tratar dos frames como repetidos.
    public static let blockLimit = 4.0
    static let cell = 3
    static let block = 16

    /// Luma promediada en celdas de 3×3, escala 0…1023. nil si el formato no es
    /// biplanar 4:2:0/4:2:2 de 8 o 10 bits.
    public struct Signature {
        let width: Int, height: Int
        let values: [UInt16]
    }

    public static func signature(_ buffer: CVPixelBuffer) -> Signature? {
        let shift: Int
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            shift = 6
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            shift = -1
        default:
            return nil
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let sw = w / cell, sh = h / cell
        guard sw >= block, sh >= block else { return nil }
        var values = [UInt16](repeating: 0, count: sw * sh)
        // Filas de celdas repartidas entre núcleos; cada tarea escribe filas disjuntas.
        let chunks = 8, rowsPerChunk = (sh + chunks - 1) / chunks
        let source = UInt(bitPattern: base)
        values.withUnsafeMutableBufferPointer { out in
            let target = UInt(bitPattern: out.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let base = UnsafeRawPointer(bitPattern: source)!
                let out = UnsafeMutablePointer<UInt16>(bitPattern: target)!
                for sy in chunk * rowsPerChunk..<min(sh, (chunk + 1) * rowsPerChunk) {
                    let y = sy * cell
                    let o = out + sy * sw
                    if shift >= 0 {
                        let r0 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                        let r1 = base.advanced(by: (y + 1) * stride).assumingMemoryBound(to: UInt16.self)
                        let r2 = base.advanced(by: (y + 2) * stride).assumingMemoryBound(to: UInt16.self)
                        for sx in 0..<sw {
                            let x = sx * cell
                            let a = UInt32(r0[x] >> 6) &+ UInt32(r0[x + 1] >> 6) &+ UInt32(r0[x + 2] >> 6)
                            let b = UInt32(r1[x] >> 6) &+ UInt32(r1[x + 1] >> 6) &+ UInt32(r1[x + 2] >> 6)
                            let c = UInt32(r2[x] >> 6) &+ UInt32(r2[x + 1] >> 6) &+ UInt32(r2[x + 2] >> 6)
                            o[sx] = UInt16((a &+ b &+ c) / 9)
                        }
                    } else {
                        let r0 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                        let r1 = base.advanced(by: (y + 1) * stride).assumingMemoryBound(to: UInt8.self)
                        let r2 = base.advanced(by: (y + 2) * stride).assumingMemoryBound(to: UInt8.self)
                        for sx in 0..<sw {
                            let x = sx * cell
                            let a = UInt32(r0[x]) &+ UInt32(r0[x + 1]) &+ UInt32(r0[x + 2])
                            let b = UInt32(r1[x]) &+ UInt32(r1[x + 1]) &+ UInt32(r1[x + 2])
                            let c = UInt32(r2[x]) &+ UInt32(r2[x + 1]) &+ UInt32(r2[x + 2])
                            o[sx] = UInt16((a &+ b &+ c) &* 4 / 9)
                        }
                    }
                }
            }
        }
        return Signature(width: sw, height: sh, values: values)
    }

    /// Máximo, sobre bloques de 16×16 celdas, de la diferencia media entre firmas.
    public static func blockMaxDifference(_ a: Signature, _ b: Signature) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let rows = a.height / block, columns = a.width / block, width = a.width
        guard rows > 0, columns > 0 else { return nil }
        var rowBest = [Int](repeating: 0, count: rows)
        a.values.withUnsafeBufferPointer { pa in
            b.values.withUnsafeBufferPointer { pb in
                rowBest.withUnsafeMutableBufferPointer { results in
                    let left = UInt(bitPattern: pa.baseAddress!), right = UInt(bitPattern: pb.baseAddress!)
                    let target = UInt(bitPattern: results.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: rows) { row in
                        let pa = UnsafePointer<UInt16>(bitPattern: left)!, pb = UnsafePointer<UInt16>(bitPattern: right)!
                        var best = 0
                        for column in 0..<columns {
                            var sum = 0
                            for y in row * block..<row * block + block {
                                let r = y * width + column * block
                                for x in 0..<block { sum += abs(Int(pa[r + x]) - Int(pb[r + x])) }
                            }
                            best = max(best, sum)
                        }
                        UnsafeMutablePointer<Int>(bitPattern: target)![row] = best
                    }
                }
            }
        }
        let best = rowBest.max() ?? 0
        return Double(best) / Double(block * block)
    }

    public static func isRepeat(_ a: Signature, _ b: Signature) -> Bool {
        guard let difference = blockMaxDifference(a, b) else { return false }
        return difference < blockLimit
    }
}
