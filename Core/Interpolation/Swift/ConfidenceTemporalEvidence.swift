import Foundation

// Separate matcher: diagnostic evidence must never mutate production search/selection state.
final class ConfidenceTemporalEvidence {
    private let matcher: MotionSearchEngine
    private let width: Int,height: Int,blockSize: Int
    private var previousA: Data?,previousB: Data?,previousReverse: [SIMD2<Int32>]?
    private var logged=0
    init(spec: [LevelSpec],lambda: UInt32,width: Int,height: Int,blockSize: Int) throws {
        matcher=try MotionSearchEngine(msl: motionShadersMSL,spec: spec,lambdaPx: lambda,smoothL0: true,gateL0: true,temporalGatePx: 0)
        self.width=width;self.height=height;self.blockSize=blockSize
    }
    func reset() {previousA=nil;previousB=nil;previousReverse=nil;matcher.resetTemporalState()}
    func acquire(a: Data,b: Data,context: DenseMotionPrototype.TemporalContext?,backward: [SIMD2<Int32>]) throws -> [SIMD4<Float>]? {
        defer {previousA=a;previousB=b;previousReverse=backward}
        guard let context else {return nil}
        let before: [SIMD2<Int32>],reused: Bool
        if previousB==a && previousA==context.before,let reverse=previousReverse {before=reverse;reused=true}
        else {_=try matcher.runPairBatched(cur: a,ref: context.before);before=matcher.downloadMV(level: 0);reused=false}
        _=try matcher.runPairBatched(cur: b,ref: context.after);let after=matcher.downloadMV(level: 0)
        let gw=(width+blockSize-1)/blockSize,gh=(height+blockSize-1)/blockSize
        guard before.count==gw*gh,after.count==before.count else {throw MotionSearchEngine.EngineError.pipeline("Temporal evidence geometry")}
        let cw=(width+7)/8,ch=(height+7)/8
        var result=[SIMD4<Float>]();result.reserveCapacity(cw*ch)
        for y in 0..<ch {for x in 0..<cw {
            let k=min(gh-1,(y*8+4)/blockSize)*gw+min(gw-1,(x*8+4)/blockSize)
            result.append(SIMD4(Float(before[k].x)/(-2*context.beforeInterval),Float(before[k].y)/(-2*context.beforeInterval),Float(after[k].x)/(-2*context.afterInterval),Float(after[k].y)/(-2*context.afterInterval)))
        }}
        if logged<5 && ProcessInfo.processInfo.environment["RIFT_DIAGNOSTICS"]=="1" {
            print("E2_TEMPORAL actual=1 searches=\(reused ? 1 : 2) previousReverseReused=\(reused) blocks=\(result.count)");logged+=1
        }
        return result
    }
}
