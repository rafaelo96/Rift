import Foundation
import CoreVideo

@main struct IdentityCheck {
    static func main() {
        for tenBit in [false,true] {
            let format=tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // Already at the output limit: processing must sharpen without resizing.
            let w=3840,h=1600
            var raw: CVPixelBuffer?
            let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String: [:],kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
            precondition(CVPixelBufferCreate(nil,w,h,format,attrs,&raw)==kCVReturnSuccess)
            let input=raw!,unit=tenBit ? 256 : 1
            func luma(_ x: Int,_ y: Int) -> Int { 32+(max(0,min(w-1,x))*7+max(0,min(h-1,y))*11)%192 }
            CVPixelBufferLockBaseAddress(input,[])
            for plane in 0..<2 {
                let pw=CVPixelBufferGetWidthOfPlane(input,plane),ph=CVPixelBufferGetHeightOfPlane(input,plane),stride=CVPixelBufferGetBytesPerRowOfPlane(input,plane)
                let base=CVPixelBufferGetBaseAddressOfPlane(input,plane)!
                for y in 0..<ph { for x in 0..<pw {
                    for channel in 0..<(plane==0 ? 1 : 2) {
                        let value=(plane==0 ? luma(x,y) : channel==0 ? 96 : 160)*unit
                        let k=x*(plane==0 ? 1 : 2)+channel
                        if tenBit { base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[k]=UInt16(value) }
                        else { base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)[k]=UInt8(value) }
                    }
                } }
            }
            CVPixelBufferUnlockBaseAddress(input,[])
            CVBufferSetAttachment(input,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
            let processor=SuperResolutionProcessor()!
            let output=processor.process(input,mode: .strong)!
            precondition(CVPixelBufferGetWidth(output)==w && CVPixelBufferGetHeight(output)==h)
            precondition(CVBufferCopyAttachment(output,kCVImageBufferColorPrimariesKey,nil) != nil)
            CVPixelBufferLockBaseAddress(output,.readOnly)
            func read(_ plane: Int,_ x: Int,_ y: Int,_ channel: Int=0) -> Int {
                let stride=CVPixelBufferGetBytesPerRowOfPlane(output,plane),base=CVPixelBufferGetBaseAddressOfPlane(output,plane)!
                let k=x*(plane==0 ? 1 : 2)+channel
                return tenBit ? Int(base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[k]) : Int(base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)[k])
            }
            for y in [0,1,237,h-1] { for x in [0,1,731,w-1] {
                let c=Float(luma(x,y)*unit),l=Float(luma(x-1,y)*unit),r=Float(luma(x+1,y)*unit),u=Float(luma(x,y-1)*unit),d=Float(luma(x,y+1)*unit)
                let lo=min(c,l,r,u,d),hi=max(c,l,r,u,d),gx=abs(r-l),gy=abs(d-u)
                let edge=1-min(gx,gy)/max(1,max(gx,gy))
                let t=max(0,min(1,(hi-lo-2)/10)),gate=t*t*(3-2*t)
                let expected=Int(max(lo,min(hi,c+(c-(l+r+u+d)*0.25)*4.75*(0.65+0.5*edge)*gate))+0.5)
                precondition(abs(read(0,x,y)-expected)<=2,"Identity sharpening changed its mathematical result")
                precondition(read(1,x/2,y/2,0)==96*unit && read(1,x/2,y/2,1)==160*unit,"Identity chroma changed")
            } }
            CVPixelBufferUnlockBaseAddress(output,.readOnly)
            var costs=[Double](),bypasses=0
            for _ in 0..<20 {
                autoreleasepool {
                    if processor.process(input,mode: .strong) != nil { costs.append(processor.lastProcessingMS) } else { bypasses+=1 }
                }
            }
            let sorted=costs.sorted()
            print("IDENTITY \(tenBit ? 10 : 8)-bit: reference/edge/chroma/metadata passed, medianMS=\(sorted.isEmpty ? 0 : sorted[sorted.count/2]), bypasses=\(bypasses)")
        }
    }
}
