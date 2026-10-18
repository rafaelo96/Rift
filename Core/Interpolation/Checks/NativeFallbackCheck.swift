#if NATIVE_FALLBACK_CHECK
import Foundation
import Metal
import CoreVideo

@main struct NativeFallbackCheck {
    static func main() throws {
        setbuf(stdout,nil)
        setenv("RIFT_DENSE_ORACLE","1",1)
        setenv("RIFT_FRAMEPLUS_F2","0",1)
        setenv("RIFT_E2","0",1)
        let w=64,h=48,n=w*h,device=MTLCreateSystemDefaultDevice()!
        let a=(0..<n).map {UInt16(100+($0*37+$0/64*51)%700)}
        let b=(0..<n).map {UInt16(120+($0*73+$0/64*23)%650)}
        func source(_ pixels: [UInt16], _ format: OSType) -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true] as CFDictionary
            precondition(CVPixelBufferCreate(nil,w,h,format,attrs,&result)==kCVReturnSuccess)
            let image=result!,ten=format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            CVPixelBufferLockBaseAddress(image,[])
            for plane in 0..<2 {
                let pw=CVPixelBufferGetWidthOfPlane(image,plane),ph=CVPixelBufferGetHeightOfPlane(image,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(image,plane),base=CVPixelBufferGetBaseAddressOfPlane(image,plane)!
                for y in 0..<ph {for x in 0..<pw {for c in 0..<(plane==0 ? 1:2) {
                    let value=plane==0 ? pixels[y*w+x] : UInt16(300+c*100)
                    if ten {base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[x*(plane==0 ? 1:2)+c]=value<<6}
                    else {base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[x*(plane==0 ? 1:2)+c]=UInt8(value/4)}
                }}}
            }
            CVPixelBufferUnlockBaseAddress(image,[]);return image
        }
        var totalFallback=0
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange] {
            let ten=format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let aa=ten ? a:a.map{$0/4*4},bb=ten ? b:b.map{$0/4*4}
            let first=source(aa,format),last=source(bb,format),warp=try WarpEngine(msl:warpShadersMSL)
            let dense=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
            let f=Array(repeating:SIMD4<Float>(12,0,0,1),count:n),r=Array(repeating:SIMD4<Float>(-12,0,0,1),count:n)
            dense.diagnosticFlowOverride={_,_ in (f,r)}
            let seeds=Array(repeating:SIMD2<Int32>.zero,count:n/64)
            for t:Float in [0.25,0.5,0.75] {
                var native: CVPixelBuffer?
                let result=try dense.interpolate(first:aa.withUnsafeBytes{Data($0)},last:bb.withUnsafeBytes{Data($0)},forward:seeds,backward:seeds,times:[t],nativeRenderer:{time,coordinates,blend,command in
                    native=warp.renderDense(I0:first,I1:last,t:time,coordinates:coordinates,blend:blend,encodingInto:command).0
                })[0]
                precondition(native != nil)
                CVPixelBufferLockBaseAddress(native!,.readOnly)
                let base=CVPixelBufferGetBaseAddressOfPlane(native!,0)!,stride=CVPixelBufferGetBytesPerRowOfPlane(native!,0)
                var maxError=0,fallback=0
                for y in 0..<h {for x in 0..<w {
                    let k=y*w+x
                    if result.reliability[k] == 0 {
                        fallback+=1
                        let raw=ten ? Int(base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[x]>>6) : Int(base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[x])*4
                        maxError=max(maxError,abs(raw-Int(result.pixels[k])))
                    }
                }}
                CVPixelBufferUnlockBaseAddress(native!,.readOnly)
                print("NATIVE FALLBACK format=\(format), t=\(t): \(fallback) pixels, max native/work error=\(maxError)")
                precondition(fallback>n/2,"Synthetic test did not exercise fallback")
                precondition(maxError <= (ten ? 2:4),"Native fallback still uses rejected warp coordinates")
                totalFallback+=fallback
            }
        }
        print("PASS: native fallback agrees with work-plane mixture on \(totalFallback) pixels; device=\(device.name)")
    }
}
#endif
