import Foundation
import Interpolation

func centeredResidual(_ a: [UInt16], _ b: [UInt16], vectors: [SIMD2<Int32>], width: Int, height: Int, block: Int = 8) -> Double {
    let gridW = (width + block - 1) / block
    func sample(_ image: [UInt16], _ px: Float, _ py: Float) -> Float {
        let x = min(Float(width-1), max(0, px)), y = min(Float(height-1), max(0, py))
        let x0 = Int(x), y0 = Int(y), x1 = min(width-1,x0+1), y1 = min(height-1,y0+1)
        let fx = x-Float(x0), fy = y-Float(y0)
        return (Float(image[y0*width+x0])*(1-fx)+Float(image[y0*width+x1])*fx)*(1-fy)
            + (Float(image[y1*width+x0])*(1-fx)+Float(image[y1*width+x1])*fx)*fy
    }
    var total = 0.0
    for y in 0..<height { for x in 0..<width {
        let v = vectors[(y/block)*gridW+x/block]
        let dx = Float(v.x)*0.25, dy = Float(v.y)*0.25
        total += Double(abs(sample(a,Float(x)-dx,Float(y)-dy)-sample(b,Float(x)+dx,Float(y)+dy)))
    } }
    return total / Double(width*height)
}

func checkCenteredRefinement() throws {
    let w = 64, h = 48
    let spec = [LevelSpec(width: w, height: h, blockSize: 8, searchHalfPel: 8, halfPelRefine: true, inheritFactor: 1)]
    let engine = try MotionSearchEngine(msl: motionShadersMSL, spec: spec, lambdaPx: 0, smoothL0: false, gateL0: false)
    let source: [UInt16] = (0..<w*h).map { i in UInt16(((i%w)*73+(i/w)*131+((i%w)*(i/w))*17)%1024) }
    let shifted: [UInt16] = (0..<w*h).map { i in source[(i/w)*w+max(0,i%w-2)] }
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    _ = engine.runPair(cur: data(source), ref: data(shifted))
    let before = engine.downloadMV(level: 0)
    let refined = try engine.experimentalCenteredRefinement()
    precondition(engine.downloadMV(level: 0) == before, "Experimental pass modified production vectors")
    let repeated = try engine.experimentalCenteredRefinement()
    precondition(refined.vectors == repeated.vectors, "Refinement is nondeterministic")
    let originalCost = centeredResidual(source, shifted, vectors: before, width: w, height: h)
    let refinedCost = centeredResidual(source, shifted, vectors: refined.vectors, width: w, height: h)
    precondition(refinedCost <= originalCost + 0.01, "Centered residual regressed")
    let constrained = try engine.experimentalCenteredRefinement(predictorWeight: 4)
    precondition(centeredResidual(source, shifted, vectors: constrained.vectors, width: w, height: h) <= originalCost + 0.01)
    let locked = try engine.experimentalCenteredRefinement(predictorWeight: 65535)
    precondition(locked.vectors == before, "Large predictor penalty failed to preserve original vectors")
    let temporal = try engine.experimentalCenteredRefinement(previous: refined.vectors)
    precondition(centeredResidual(source, shifted, vectors: temporal.vectors, width: w, height: h) <= originalCost + 0.01)
    do {
        _ = try engine.experimentalCenteredRefinement(previous: [])
        preconditionFailure("Invalid temporal grid accepted")
    } catch MotionSearchEngine.EngineError.pipeline { }
    let coherent = refined.vectors.enumerated().filter { index, vector in index%8>0 && index%8<7 && vector == SIMD2<Int32>(4,0) }.count
    precondition(coherent >= 24, "Known translation was not recovered")
    _ = engine.runPair(cur: data(source), ref: data(source))
    let staticResult = try engine.experimentalCenteredRefinement()
    precondition(staticResult.vectors.allSatisfy { $0 == .zero }, "Static frame acquired motion")
    print("CENTERED CHECK: translation, static frame, deterministic output and production field preservation passed")
}
