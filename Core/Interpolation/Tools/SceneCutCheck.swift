import Foundation
import CoreVideo
import Interpolation

// Frame+ scene-cut gate: an unrelated pair must repeat the source frames;
// a rigid pan of the same content must still be interpolated.
func checkSceneCutGate() throws {
    let w=1024,h=432
    func image(_ seed: Double,_ shift: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true] as CFDictionary
        precondition(CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,attrs,&result)==kCVReturnSuccess)
        let buffer=result!;CVPixelBufferLockBaseAddress(buffer,[])
        for plane in 0..<2 {
            let pw=CVPixelBufferGetWidthOfPlane(buffer,plane),ph=CVPixelBufferGetHeightOfPlane(buffer,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
            let base=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!
            for y in 0..<ph {
                let row=base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)
                for x in 0..<pw*(plane==0 ? 1:2) {
                    var value=512.0
                    if plane==0 {
                        let u=Double(x+shift),v=Double(y)
                        value=512+180*sin(u*0.031*seed+v*0.017)+140*sin(v*0.043*seed-u*0.011+seed)+90*sin((u+v)*0.07/seed)
                    }
                    row[x]=UInt16(max(64,min(940,value)))<<6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[]);return buffer
    }
    let engine=try MotionCompensator(config:InterpolationConfig.fluid.fittingAspect(width:w,height:h))
    let a=image(1.0,0)
    let cut=engine.interpolatePair(I0:a,I1:image(2.3,0),tValues:[0.25,0.5,0.75]).pixelBuffers
    precondition(cut.count==3 && cut[0]===a && cut[1]===a && cut[2] !== a,"Unrelated pair was interpolated instead of repeating sources")
    engine.resetTemporalState()
    let pan=engine.interpolatePair(I0:a,I1:image(1.0,12),tValues:[0.5]).pixelBuffers
    precondition(pan.count==1 && pan[0] !== a,"Rigid pan was rejected as a scene cut")
    // Detector cost on a 4K-sized work plane level 1 (560x240, 35x15 blocks).
    let lw=560,lh=240,gw=35,gh=15
    let cur=(0..<lw*lh).map {UInt16(($0*7919)%1024)},ref=(0..<lw*lh).map {UInt16(($0*104729)%1024)}
    let vectors=(0..<gw*gh).map {SIMD2<Int32>(Int32($0%9)-4,Int32($0%5)-2)}
    var sink=0.0;let start=DispatchTime.now().uptimeNanoseconds
    for _ in 0..<200 {sink+=SceneCutDetector.unmatchedFraction(cur:cur,ref:ref,width:lw,height:lh,vectors:vectors,gridW:gw,gridH:gh,blockSize:16)}
    let ms=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6/200
    print("SCENE CUT: unrelated pair repeats sources; rigid pan interpolated; detector \(String(format:"%.3f",ms)) ms/pair (\(sink>0 ? "ok":"zero"))")
}
