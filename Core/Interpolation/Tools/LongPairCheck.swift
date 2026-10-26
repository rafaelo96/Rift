import Foundation
import CoreVideo
import Interpolation

// A pair spanning two source periods (repeated frame dropped by FramePool) is
// sampled at five 60 fps grid points. Each output must sit at t × displacement
// along a rigid pan, so motion is spread evenly instead of stop-and-jump.
func checkLongPair() throws {
    let w=1024,h=432,total=24
    func image(_ shift: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true] as CFDictionary
        precondition(CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,attrs,&result)==kCVReturnSuccess)
        let buffer=result!;CVPixelBufferLockBaseAddress(buffer,[])
        for plane in 0..<2 {
            let pw=CVPixelBufferGetWidthOfPlane(buffer,plane),ph=CVPixelBufferGetHeightOfPlane(buffer,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
            let base=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!
            for y in 0..<ph {let row=base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)
                for x in 0..<pw*(plane==0 ? 1:2) {
                    let u=Double(x+shift),v=Double(y)
                    let value=plane==0 ? 512+180*sin(u*0.031+v*0.017)+140*sin(v*0.043-u*0.011+1)+90*sin((u+v)*0.07) : 512
                    row[x]=UInt16(max(64,min(940,value)))<<6
                }}
        }
        CVPixelBufferUnlockBaseAddress(buffer,[]);return buffer
    }
    func luma(_ buffer: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        return (0..<h).flatMap {y in (0..<w).map {Int(base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[$0]>>6)}}
    }
    let reference=luma(image(0))
    // Sub-pixel shift of an output against I0 over the central region (SAD minimum, parabolic fit).
    func shift(_ frame: [Int],limit: Int) -> Double {
        var costs=[Double]()
        for s in 0...limit {
            var sad=0
            for y in stride(from:100,to:h-100,by:2) {for x in stride(from:200,to:w-260,by:2) {sad+=abs(frame[y*w+x]-reference[y*w+x+s])}}
            costs.append(Double(sad))
        }
        let best=costs.indices.min {costs[$0]<costs[$1]}!
        guard best>0,best<costs.count-1 else {return Double(best)}
        let a=costs[best-1],b=costs[best],c=costs[best+1]
        return Double(best)+0.5*(a-c)/max(a-2*b+c,1e-9)
    }
    let engine=try MotionCompensator(config:InterpolationConfig.fluid.fittingAspect(width:w,height:h))
    // Two periods (one repeat dropped): five samples; three periods (two dropped): seven.
    for (periods,times) in [(2,[Float(0.1),0.3,0.5,0.7,0.9]),(3,(1...7).map {Float($0)/7.5})] {
        let span=total*periods/2
        engine.resetTemporalState()
        let outputs=engine.interpolatePair(I0:image(0),I1:image(span),tValues:times).pixelBuffers
        guard outputs.count==times.count else {print("LONG PAIR CHECK FAILED: \(outputs.count) outputs for \(times.count) samples");exit(3)}
        let shifts=outputs.map {shift(luma($0),limit:span+4)}
        let errors=zip(times,shifts).map {abs($1-Double($0)*Double(span))}
        print("LONG PAIR \(periods) periods: shifts \(shifts.map {String(format:"%.2f",$0)}.joined(separator:" ")) expected \(times.map {String(format:"%.1f",Double($0)*Double(span))}.joined(separator:" "))")
        guard errors.allSatisfy({$0<1}),zip(shifts,shifts.dropFirst()).allSatisfy({$0<$1}) else {print("LONG PAIR CHECK FAILED: uneven motion");exit(3)}
        print("LONG PAIR: \(times.count) samples over \(periods) periods advance evenly (max error \(String(format:"%.2f",errors.max()!)) px)")
    }
}
