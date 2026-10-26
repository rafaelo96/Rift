import Foundation
import CoreVideo
import Interpolation

// Offline simulation of the 60 fps presentation with and without dropping repeated
// source frames before pairing. Uses production MotionCompensator (economy profile,
// as admitted at 4K on M4) on an epoch-based 1/60 grid like UniformCadence. Per
// output step it measures global motion (median vector between consecutive
// outputs) to quantify stop-go judder, plus far-from-both on synthesized frames.
func simulateDedup(buffers: [CVPixelBuffer], pts: [Double], output: String) throws {
    let w=CVPixelBufferGetWidth(buffers[0]),h=CVPixelBufferGetHeight(buffers[0])
    let config=InterpolationConfig.fluidEconomy.fittingAspect(width:w,height:h)
    let mw=576,mh=240
    let threshold=Double(ProcessInfo.processInfo.environment["MV_DEDUP_BLOCKMAX"] ?? "1.5")!
    func plane(_ buffer: CVPixelBuffer,_ ow: Int,_ oh: Int) -> [UInt16] {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        var out=[UInt16](repeating:0,count:ow*oh)
        for y in 0..<oh {for x in 0..<ow {
            let x0=x*w/ow,x1=max(x0+1,(x+1)*w/ow),y0=y*h/oh,y1=max(y0+1,(y+1)*h/oh)
            var sum=0;for yy in y0..<y1 {let row=base.advanced(by:yy*stride).assumingMemoryBound(to:UInt16.self);for xx in x0..<x1 {sum+=Int(row[xx]>>6)}}
            out[y*ow+x]=UInt16(sum/((x1-x0)*(y1-y0)))
        }}
        return out
    }
    // Duplicate evidence: max over 16x16 blocks of mean |a-b| on a 1/3 decimated plane.
    let dw=w/3,dh=h/3
    let small=buffers.map {plane($0,dw,dh)}
    func blockMax(_ a: [UInt16],_ b: [UInt16]) -> Double {
        var best=0.0
        for by in stride(from:0,to:dh-15,by:16) {for bx in stride(from:0,to:dw-15,by:16) {
            var sum=0;for y in by..<by+16 {for x in bx..<bx+16 {sum+=abs(Int(a[y*dw+x])-Int(b[y*dw+x]))}}
            best=max(best,Double(sum)/256)
        }}
        return best
    }
    var dropped=Set<Int>()
    for j in 1..<buffers.count-1 where !dropped.contains(j-1) && blockMax(small[j-1],small[j])<threshold {dropped.insert(j)}
    let spec=[LevelSpec(width:mw,height:mh,blockSize:16,searchHalfPel:16,halfPelRefine:false,inheritFactor:1)]
    let probe=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:1,smoothL0:true,gateL0:true,temporalGatePx:0)
    func globalMotion(_ a: [UInt16],_ b: [UInt16]) -> Double {
        _=probe.runPair(cur:a.withUnsafeBytes {Data($0)},ref:b.withUnsafeBytes {Data($0)})
        let mv=probe.downloadMV(level:0).map {hypot(Double($0.x),Double($0.y))/2*Double(w)/Double(mw)}
        return mv.sorted()[mv.count/2]
    }
    var report=[String:Any]()
    for (mode,kept) in [("current",Array(0..<buffers.count)),("dedup",(0..<buffers.count).filter {!dropped.contains($0)})] {
        let engine=try MotionCompensator(config:config)
        let step=1.0/60,epoch=pts[0]
        var previous: [UInt16]?,motions=[Double](),changes=[Double](),pairCosts=[Double](),incomplete=0,farValues=[Double](),costMS=0.0,pairs=0,synthesized=0
        for p in 1..<kept.count-2 {
            let ia=kept[p],ib=kept[p+1],pa=pts[ia],pb=pts[ib]
            var times=[Double]();var k=ceil((pa-epoch)/step-1e-6)
            while epoch+k*step<pb-1e-7 {times.append(epoch+k*step);k+=1}
            let tol=0.001
            let tValues=times.map {Float(($0-pa)/(pb-pa))}.filter {Double($0)*(pb-pa)>tol && (1-Double($0))*(pb-pa)>tol}
            let context=InterpolationTemporalContext(before:buffers[kept[p-1]],after:buffers[kept[p+2]],beforeInterval:Float((pa-pts[kept[p-1]])/(pb-pa)),afterInterval:Float((pts[kept[p+2]]-pb)/(pb-pa)))
            var generated=[CVPixelBuffer]()
            if !tValues.isEmpty {
                let start=DispatchTime.now().uptimeNanoseconds
                generated=engine.interpolatePair(I0:buffers[ia],I1:buffers[ib],tValues:tValues,context:context).pixelBuffers
                let pairMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
                costMS+=pairMS;pairs+=1;synthesized+=generated.count;pairCosts.append(pairMS)
                if generated.count != tValues.count {incomplete+=1}
            }
            let a=plane(buffers[ia],mw,mh),b=plane(buffers[ib],mw,mh)
            var g=0
            for time in times {
                let t=(time-pa)/(pb-pa)
                let frame: [UInt16]
                if t*(pb-pa)<=tol {frame=a}
                else if g<generated.count {
                    frame=plane(generated[g],mw,mh);g+=1
                    var far=0
                    for i in frame.indices where abs(Int(a[i])-Int(b[i]))>40 {if min(abs(Int(frame[i])-Int(a[i])),abs(Int(frame[i])-Int(b[i])))>40 {far+=1}}
                    farValues.append(Double(far)/Double(frame.count))
                } else {frame=a}
                if let previous {
                    motions.append(globalMotion(previous,frame))
                    changes.append(Double(zip(previous,frame).filter {abs(Int($0)-Int($1))>8}.count)/Double(frame.count))
                }
                previous=frame
            }
        }
        // Stop-go: a near-still step surrounded by clearly moving steps.
        var stalls=0,moving=0,variation=0.0,variationN=0
        if motions.count>4 {
            for i in 2..<motions.count-2 {
                let around=[motions[i-2],motions[i-1],motions[i+1],motions[i+2]]
                if around.max()!>2 {moving+=1;if motions[i]<0.5 {stalls+=1}}
                let mean=motions[i-2...i+2].reduce(0,+)/5
                if mean>2 {variation+=abs(motions[i]-motions[i-1])/mean;variationN+=1}
            }
        }
        // Frozen step: consecutive outputs (nearly) identical while the content around moves.
        var frozen=0,active=0
        if changes.count>6 {
            for i in 3..<changes.count-3 where changes[i-3...i+3].max()!>0.01 {active+=1;if changes[i]<0.001 {frozen+=1}}
        }
        let frozenFraction=active==0 ? 0:Double(frozen)/Double(active)
        let stall=moving==0 ? 0:Double(stalls)/Double(moving),stepVariation=variationN==0 ? 0:variation/Double(variationN)
        let meanFar=farValues.isEmpty ? 0:farValues.reduce(0,+)/Double(farValues.count)
        report[mode]=["outputs":motions.count+1,"pairs":pairs,"synthesized":synthesized,"costMS":costMS,
                      "stallFraction":stall,"pairCostMax":pairCosts.max() ?? 0,"pairCostP95":pairCosts.isEmpty ? 0:pairCosts.sorted()[Int(Double(pairCosts.count-1)*0.95)],"incompletePairs":incomplete,"frozenFraction":frozenFraction,"activeSteps":active,"changes":changes,"stepVariation":stepVariation,"meanFar":meanFar,"motions":motions]
        print("DEDUP \(mode): frozen \(String(format:"%.3f",frozenFraction)) of \(active) pairs \(pairs) synth \(synthesized) stall \(String(format:"%.3f",stall)) variation \(String(format:"%.3f",stepVariation)) far \(String(format:"%.4f",meanFar)) cost \(String(format:"%.0f",costMS)) ms p95 \(String(format:"%.1f",pairCosts.isEmpty ? 0:pairCosts.sorted()[Int(Double(pairCosts.count-1)*0.95)])) max \(String(format:"%.1f",pairCosts.max() ?? 0)) incomplete \(incomplete)")
    }
    report["dropped"]=dropped.sorted();report["threshold"]=threshold;report["sourceFrames"]=buffers.count
    try confidenceJSON(report,output+"/dedup.json")
}
