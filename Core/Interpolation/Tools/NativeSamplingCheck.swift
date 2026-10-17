#if NATIVE_SAMPLING_CHECK
import Foundation
import Metal
import CoreVideo

@main struct NativeSamplingCheck {
    static func checkImmediateNearest() throws {
        let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
        let local=try LocalConfidenceDegradation(device:device,width:16,height:16)
        let signals=(0..<4).flatMap { _ in [SIMD4<Float>(1e6,1e6,1,1e6),SIMD4<Float>(1e6,0.5,0,0)] }
        let buffer=signals.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:16,height:16,mipmapped:false);descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.shaderWrite]
        let flow=device.makeTexture(descriptor:descriptor)!,zeros=[SIMD4<Float>](repeating:.zero,count:256)
        zeros.withUnsafeBytes{flow.replace(region:MTLRegionMake2D(0,0,16,16),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256)}
        let command=queue.makeCommandBuffer()!;try local.prepare(command:command,signals:buffer,forward:flow,step:1);command.commit();command.waitUntilCompleted();precondition(command.status == .completed)
        var map=[SIMD4<Float>](repeating:.zero,count:256)
        map.withUnsafeMutableBytes{local.map.getBytes($0.baseAddress!,bytesPerRow:256,from:MTLRegionMake2D(0,0,16,16),mipmapLevel:0)}
        precondition(map.allSatisfy{$0.x>0.3 && $0.y==1},"Large A-B must choose nearest from the first pair")
        print("E2 CONFIDENCE MODE: high-risk, dissimilar A/B selects nearest immediately on first pair")
    }
    static func main() throws {
        try checkImmediateNearest()
        let formats: [(Bool,OSType,String)]=[(false,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,"NV12"),(true,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,"P010"),(true,kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,"P210")]
        for (tenBit,format,label) in formats { for small in [false,true] {
            let engine=try WarpEngine(msl: warpShadersMSL)
            let w=small ? 2 : 64,h=small ? 2 : 48,mw=8,mh=6
            func pixel(_ frame: Int,_ plane: Int,_ x: Int,_ y: Int,_ channel: Int) -> UInt16 {
                let n=(x*37+y*61+x*y*3+frame*83+channel*47+plane*19)%(tenBit ? 1024 : 256)
                return UInt16(n)*(tenBit ? 64 : 1)
            }
            func source(_ frame: Int,_ width: Int,_ height: Int) -> CVPixelBuffer {
                var result: CVPixelBuffer?
                let attributes=[kCVPixelBufferIOSurfacePropertiesKey as String: [:],kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
                precondition(CVPixelBufferCreate(nil,width,height,format,attributes,&result)==kCVReturnSuccess)
                let image=result!
                CVPixelBufferLockBaseAddress(image,[])
                for plane in 0..<2 {
                    let pw=CVPixelBufferGetWidthOfPlane(image,plane),ph=CVPixelBufferGetHeightOfPlane(image,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(image,plane)
                    let base=CVPixelBufferGetBaseAddressOfPlane(image,plane)!,channels=plane==0 ? 1 : 2
                    for y in 0..<ph { for x in 0..<pw { for c in 0..<channels {
                        let k=x*channels+c,value=pixel(frame,plane,x,y,c)
                        if tenBit { base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[k]=value }
                        else { base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)[k]=UInt8(value) }
                    } } }
                }
                CVPixelBufferUnlockBaseAddress(image,[])
                return image
            }
            func texture(_ format: MTLPixelFormat) -> MTLTexture {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: mw,height: mh,mipmapped: false)
                d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
                return engine.device.makeTexture(descriptor: d)!
            }
            let coordinates=texture(.rgba32Float),blend=texture(.r32Float)
            let maps=(0..<mw*mh).map { k in SIMD4<Float>(sin(Float(k))*3.73,cos(Float(k))*2.19,cos(Float(k))*4.13,sin(Float(k))*2.67) }
            let weights=(0..<mw*mh).map { [Float(0),0.13,0.5,0.87,1][$0%5] }
            maps.withUnsafeBytes { coordinates.replace(region: MTLRegionMake2D(0,0,mw,mh),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: mw*16) }
            weights.withUnsafeBytes { blend.replace(region: MTLRegionMake2D(0,0,mw,mh),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: mw*4) }
            let a=source(0,w,h),b=source(1,w,h)
            let output=engine.renderDense(I0: a,I1: b,t: 0.5,coordinates: coordinates,blend: blend).0!
            CVPixelBufferLockBaseAddress(output,.readOnly)
            var total=0.0,maximum=0,count=0
            func sample(_ frame: Int,_ plane: Int,_ p: SIMD2<Float>,_ channel: Int,_ width: Int,_ height: Int) -> Float {
                let x=max(0,min(Float(width-1),p.x)),y=max(0,min(Float(height-1),p.y))
                let ix=Int(floor(x)),iy=Int(floor(y)),jx=min(width-1,ix+1),jy=min(height-1,iy+1)
                let fx=x-Float(ix),fy=y-Float(iy)
                let top=Float(pixel(frame,plane,ix,iy,channel))*(1-fx)+Float(pixel(frame,plane,jx,iy,channel))*fx
                let bottom=Float(pixel(frame,plane,ix,jy,channel))*(1-fx)+Float(pixel(frame,plane,jx,jy,channel))*fx
                return top*(1-fy)+bottom*fy
            }
            for plane in 0..<2 {
                let pw=CVPixelBufferGetWidthOfPlane(output,plane),ph=CVPixelBufferGetHeightOfPlane(output,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(output,plane)
                let base=CVPixelBufferGetBaseAddressOfPlane(output,plane)!,channels=plane==0 ? 1 : 2
                let scale=SIMD2<Float>(Float(mw)/Float(pw),Float(mh)/Float(ph))
                for y in 0..<ph { for x in 0..<pw {
                    let p=SIMD2<Float>(Float(x),Float(y)),work=(p+0.5)*scale-0.5
                    let cellX=max(0,min(mw-1,Int(work.x.rounded()))),cellY=max(0,min(mh-1,Int(work.y.rounded())))
                    let index=cellY*mw+cellX,motion=maps[index],alpha=weights[index]
                    for c in 0..<channels {
                        let p0=p+SIMD2<Float>(motion.x,motion.y)/scale,p1=p+SIMD2<Float>(motion.z,motion.w)/scale
                        let unit: Float=tenBit ? 64 : 1
                        let value=sample(0,plane,p0,c,pw,ph)*(1-alpha)+sample(1,plane,p1,c,pw,ph)*alpha
                        let expected=Int(max(0,min(tenBit ? 1023 : 255,(value/unit).rounded())))
                        let k=x*channels+c
                        let raw=tenBit ? Int(base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[k]) : Int(base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)[k])
                        if tenBit { precondition(raw%64==0,"P010 low bits changed") }
                        let error=abs(raw/Int(unit)-expected)
                        maximum=max(maximum,error); total+=Double(error); count+=1
                    }
                } }
            }
            CVPixelBufferUnlockBaseAddress(output,.readOnly)
            let mae=total/Double(count)
            print("NATIVE SAMPLING \(label) \(w)x\(h): MAE=\(mae), max=\(maximum) source code values")
            precondition(maximum <= (tenBit ? 2 : 1) && mae<0.25,"Native color sampling lost precision")
            if ProcessInfo.processInfo.environment["RIFT_E2"]=="1" {
                let local=texture(.rgba32Float)
                let reference=engine.renderDense(I0:a,I1:b,t:0.75,coordinates:coordinates,blend:blend).0!
                for weight in [Float(0),1] {for mode in [Float(0),1] {
                    let values=Array(repeating:SIMD4<Float>(weight,mode,0,0),count:mw*mh)
                    values.withUnsafeBytes {local.replace(region:MTLRegionMake2D(0,0,mw,mh),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:mw*16)}
                    let actual=engine.renderDense(I0:a,I1:b,t:0.75,coordinates:coordinates,blend:blend,degradation:local).0!
                    CVPixelBufferLockBaseAddress(actual,.readOnly)
                    CVPixelBufferLockBaseAddress(reference,.readOnly)
                    for plane in 0..<2 {
                        let pw=CVPixelBufferGetWidthOfPlane(actual,plane),ph=CVPixelBufferGetHeightOfPlane(actual,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(actual,plane),channels=plane==0 ? 1:2
                        let bytes=CVPixelBufferGetBaseAddressOfPlane(actual,plane)!
                        for y in 0..<ph {for x in 0..<pw {for c in 0..<channels {
                            let k=x*channels+c,unit=tenBit ? 64:1
                            let raw=tenBit ? Int(bytes.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[k]):Int(bytes.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[k])
                            if weight==0 {
                                let rb=CVPixelBufferGetBaseAddressOfPlane(reference,plane)!,rs=CVPixelBufferGetBytesPerRowOfPlane(reference,plane)
                                let expected=tenBit ? Int(rb.advanced(by:y*rs).assumingMemoryBound(to:UInt16.self)[k]):Int(rb.advanced(by:y*rs).assumingMemoryBound(to:UInt8.self)[k])
                                precondition(raw==expected,"Trusted native pixel changed")
                            }
                            if weight==1 {
                                let aa=Float(pixel(0,plane,x,y,c)),bb=Float(pixel(1,plane,x,y,c));let expected=mode==1 ? bb:aa*0.25+bb*0.75
                                precondition(abs(raw/unit-Int((expected/Float(unit)).rounded()))<=1,"Native local fallback value or chroma wrong")
                            }
                        }}}
                    }
                    CVPixelBufferUnlockBaseAddress(actual,.readOnly)
                    CVPixelBufferUnlockBaseAddress(reference,.readOnly)
                }}
                print("NATIVE E2 fallback endpoints/blend: \(label) \(w)x\(h) passed")
            }
            if small { continue }
            let bigA=source(0,3840,1600),bigB=source(1,3840,1600)
            var costs=[Double]()
            for _ in 0..<12 { autoreleasepool {
                let result=engine.renderDense(I0: bigA,I1: bigB,t: 0.5,coordinates: coordinates,blend: blend)
                precondition(result.0 != nil)
                costs.append(result.1)
            } }
            print("NATIVE SAMPLING 4K \(label) median=\(costs.dropFirst().sorted()[5])ms")
        } }
    }
}
#endif
