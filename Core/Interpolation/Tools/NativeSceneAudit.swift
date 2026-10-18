import Foundation
import CoreVideo
import Interpolation
import CryptoKit

func auditNativeScene(buffers: [CVPixelBuffer], pts: [Double], output: String) throws {
    try FileManager.default.createDirectory(atPath: output,withIntermediateDirectories: true)
    func luma(_ buffer: CVPixelBuffer) -> [UInt16] {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let w=CVPixelBufferGetWidth(buffer),h=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
        let base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        let ten=CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var pixels=[UInt16](repeating:0,count:w*h)
        for y in 0..<h {for x in 0..<w {pixels[y*w+x]=ten ? base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[x]>>6 : UInt16(base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[x])*4}}
        return pixels
    }
    let w=CVPixelBufferGetWidth(buffers[0]),h=CVPixelBufferGetHeight(buffers[0])
    let profile=ProcessInfo.processInfo.environment["MV_NATIVE_SCENE_PROFILE"] ?? "economy"
    let fitted=(profile=="fluid" ? InterpolationConfig.fluid : InterpolationConfig.fluidEconomy).fittingAspect(width:w,height:h)
    let unsafe = ProcessInfo.processInfo.environment["MV_NATIVE_SCENE_UNSAFE"] == "1"
    let config = unsafe ? InterpolationConfig(workWidth:fitted.workWidth,workHeight:fitted.workHeight,usesBidirectionalSafetyCheck:false,usesCatastrophicSafetyCheck:false) : fitted
    let engine=try MotionCompensator(config:config)
    var rows=[[String:Any]]()
    for i in 1..<buffers.count-2 {
        let context=InterpolationTemporalContext(before:buffers[i-1],after:buffers[i+2],beforeInterval:Float((pts[i]-pts[i-1])/(pts[i+1]-pts[i])),afterInterval:Float((pts[i+2]-pts[i+1])/(pts[i+1]-pts[i])))
        let batch=engine.interpolatePair(I0:buffers[i],I1:buffers[i+1],tValues:[0.25,0.5,0.75],context:context).pixelBuffers
        precondition(batch.count==3)
        let pixels=luma(batch[1])
        let single=engine.interpolatePair(I0:buffers[i],I1:buffers[i+1],tValues:[0.5],context:context).pixelBuffers
        precondition(single.count==1)
        let singlePixels=luma(single[0]);let changed=zip(pixels,singlePixels).filter{$0 != $1}.count
        rows.append(["first":i,"PTS":[pts[i],pts[i+1]],"batchSingleChanged":changed,"midpointIsSource":batch[1] === buffers[i],"quarterIsSource":batch[0] === buffers[i]])
        confidencePNG(pixels,w,h,output+"/pair\(i)-batch.png")
        confidencePNG(singlePixels,w,h,output+"/pair\(i)-single.png")
        confidencePNG(luma(buffers[i]),w,h,output+"/pair\(i)-A.png")
        confidencePNG(luma(buffers[i+1]),w,h,output+"/pair\(i)-B.png")
        print("NATIVE SCENE \(i): batch/single changed \(changed)")
    }
    try confidenceJSON(["width":w,"height":h,"workWidth":config.workWidth,"workHeight":config.workHeight,"records":rows],output+"/metrics.json")
}

// Fails on the old patch path, which ignored both configured safety checks.
func checkNativePatchSafety() throws {
    func buffer(_ frame: Int, _ format: OSType, _ pattern: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true] as CFDictionary
        precondition(CVPixelBufferCreate(nil,128,64,format,attrs,&result)==kCVReturnSuccess)
        let image=result!, ten=format==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        CVPixelBufferLockBaseAddress(image,[])
        for plane in 0..<2 {
            let w=CVPixelBufferGetWidthOfPlane(image,plane),h=CVPixelBufferGetHeightOfPlane(image,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(image,plane),channels=plane==0 ? 1:2
            let base=CVPixelBufferGetBaseAddressOfPlane(image,plane)!
            for y in 0..<h {for x in 0..<w {for c in 0..<channels {
                var seed=UInt32(x+y*128+frame*13579)&*1664525&+1013904223
                seed ^= seed>>13;seed=seed&*2246822519;seed ^= seed>>16
                let value: Int
                if plane==1 {value=128}
                else if pattern==0 {value=64+Int(seed%128)}
                else if pattern==1 {value=128}
                else if pattern==2 {value=80+x/2}
                else if pattern==3 {value=x<64 ? 80:160}
                else if pattern==4 {value=(x/8+y/8)%2==0 ? 90:150}
                else if pattern==5 {value=100+(x%16)*3}
                else {value=100+(y%16)*3}
                let k=x*channels+c
                if ten {base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[k]=UInt16(value*4)<<6}
                else {base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[k]=UInt8(value)}
            }}}
        }
        CVPixelBufferUnlockBaseAddress(image,[]);return image
    }
    func bytes(_ image: CVPixelBuffer)->Data {
        CVPixelBufferLockBaseAddress(image,.readOnly);defer {CVPixelBufferUnlockBaseAddress(image,.readOnly)}
        var data=Data();let ten=CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        for p in 0..<2 {
            let count=CVPixelBufferGetWidthOfPlane(image,p)*(p==0 ? 1:2)*(ten ? 2:1),stride=CVPixelBufferGetBytesPerRowOfPlane(image,p),base=CVPixelBufferGetBaseAddressOfPlane(image,p)!
            for y in 0..<CVPixelBufferGetHeightOfPlane(image,p) {data.append(base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self),count:count)}
        };return data
    }
    for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
        let engine=try MotionCompensator(config:InterpolationConfig(workWidth:128,workHeight:64))
        let a=buffer(0,format,0),b=buffer(1,format,0)
        let rejected=engine.interpolatePair(I0:a,I1:b,tValues:[0,0.25,0.5,0.75,1].filter{$0 != 0.5}).pixelBuffers
        precondition(rejected.count==4 && rejected[1] === a && rejected[2] === b,"Patch path bypasses configured rejection of inconsistent motion")
        let allowed=try MotionCompensator(config:InterpolationConfig(workWidth:128,workHeight:64,usesBidirectionalSafetyCheck:false,usesCatastrophicSafetyCheck:false))
        let synthesized=allowed.interpolatePair(I0:a,I1:b,tValues:[0.5]).pixelBuffers
        precondition(synthesized.count==1 && synthesized[0] !== a && synthesized[0] !== b,"Explicit safety opt-out was ignored")
        for pattern in 1...6 {
            let still=buffer(0,format,pattern),expected=bytes(still)
            let output=engine.interpolatePair(I0:still,I1:still,tValues:[0.25,0.5,0.75]).pixelBuffers
            precondition(output.count==3 && output.allSatisfy{bytes($0)==expected},"Static native control changed")
        }
    }
    print("PATCH SAFETY: configured rejection and opt-out passed; 12 static controls exactly unchanged")
}
