import Foundation
import CoreVideo
import Interpolation

// Startup cost of re-enabling Frame+: MotionCompensator init and the first pairs
// at a 4K-sized input, with each optional stage toggled through its env switch.
func checkCompensatorStartup() throws {
    let w=3832,h=1600
    func image(_ shift: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true] as CFDictionary
        precondition(CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,attrs,&result)==kCVReturnSuccess)
        let buffer=result!;CVPixelBufferLockBaseAddress(buffer,[])
        for plane in 0..<2 {
            let pw=CVPixelBufferGetWidthOfPlane(buffer,plane),ph=CVPixelBufferGetHeightOfPlane(buffer,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
            let base=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!
            for y in 0..<ph {let row=base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)
                for x in 0..<pw*(plane==0 ? 1:2) {row[x]=plane==0 ? UInt16(512+300*sin(Double(x+shift)*0.02+Double(y)*0.013))<<6 : 512<<6}}
        }
        CVPixelBufferUnlockBaseAddress(buffer,[]);return buffer
    }
    let frames=(0..<8).map {image($0*6)}
    let config=InterpolationConfig.fluid.fittingAspect(width:w,height:h)
    func ms(_ start: UInt64) -> Double {Double(DispatchTime.now().uptimeNanoseconds-start)/1e6}
    let order=ProcessInfo.processInfo.environment["MV_STARTUP_ORDER"]=="off-first" ? [("hold off","0"),("hold on","1"),("hold off","0"),("hold on","1")] : [("hold on","1"),("hold off","0"),("hold on","1"),("hold off","0")]
    for (label,hold) in order {
        setenv("RIFT_DRAWING_HOLD",hold,1)
        var start=DispatchTime.now().uptimeNanoseconds
        let engine=try MotionCompensator(config:config)
        let initMS=ms(start)
        var pairs=[Double]()
        for i in 0..<6 {start=DispatchTime.now().uptimeNanoseconds;_=engine.interpolatePair(I0:frames[i],I1:frames[i+1],tValues:[0.5]);pairs.append(ms(start))}
        print("STARTUP \(label): init \(String(format:"%.0f",initMS)) ms, pairs \(pairs.map {String(format:"%.0f",$0)}.joined(separator:" ")) ms")
    }
    unsetenv("RIFT_DRAWING_HOLD")
}
