import Foundation

// MARK: - SceneCutDetector
//
// Corte de escena = par sin correspondencia espacial: tras compensar con los
// vectores de nivel 1 de la pirámide ME, casi ningún bloque coincide. Un
// histograma de luma no sirve (un plano que gira puntúa como un corte); el
// residuo compensado sí separa. Calibrado offline (MVProbe MV_CUT_FEATURES=1,
// Avatar 2026 4K HDR, 2878 pares etiquetados a mano, Apple M4): > 0.61 de
// bloques con residuo medio > 24/1023 → 29/41 cortes, 0/2809 pares del mismo
// plano. Los cortes que escapan tienen contenido similar a ambos lados.
// Ver commit 79af2c8.

public enum SceneCutDetector {
    /// Residuo medio por bloque (luma 0...1023 del work-plane) para contar el bloque como sin correspondencia.
    public static let blockResidualLimit = 24
    /// Fracción de bloques sin correspondencia a partir de la cual el par se trata como corte.
    public static let unmatchedFractionLimit = 0.61

    /// Fracción de bloques cuyo residuo medio, desplazando `ref` por el vector
    /// del bloque (half-pel, se usa el píxel entero), supera `blockResidualLimit`.
    public static func unmatchedFraction(cur: [UInt16], ref: [UInt16], width: Int, height: Int,
                                         vectors: [SIMD2<Int32>], gridW: Int, gridH: Int,
                                         blockSize: Int) -> Double {
        guard width > 0, height > 0, cur.count == width * height, ref.count == cur.count,
              gridW > 0, gridH > 0, vectors.count == gridW * gridH else { return 0 }
        var unmatched = 0
        cur.withUnsafeBufferPointer { a in
            ref.withUnsafeBufferPointer { b in
                for by in 0..<gridH {
                    for bx in 0..<gridW {
                        let v = vectors[by * gridW + bx]
                        let dx = Int(v.x) / 2, dy = Int(v.y) / 2
                        var sum = 0, n = 0
                        for y in by * blockSize..<min(by * blockSize + blockSize, height) {
                            let ry = min(max(y + dy, 0), height - 1)
                            for x in bx * blockSize..<min(bx * blockSize + blockSize, width) {
                                let rx = min(max(x + dx, 0), width - 1)
                                sum += abs(Int(a[y * width + x]) - Int(b[ry * width + rx]))
                                n += 1
                            }
                        }
                        if n > 0 && Double(sum) / Double(n) > Double(blockResidualLimit) { unmatched += 1 }
                    }
                }
            }
        }
        return Double(unmatched) / Double(gridW * gridH)
    }

    public static func isCut(unmatchedFraction: Double) -> Bool {
        unmatchedFraction > unmatchedFractionLimit
    }
}
