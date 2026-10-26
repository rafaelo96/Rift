import Foundation
import CoreVideo
import CoreImage
import Interpolation

// Offline native-colour preview of holding the source drawing. The production
// Frame+ output (MotionCompensator, sequential pairs) is composited with I0
// through a smooth per-pixel mask: work-plane pixels without correspondence
// (dense reliability < 0.02), box-blurred, then smoothstep. No production change.
func previewDrawingHoldNative(buffers: [CVPixelBuffer], pts: [Double], output: String) throws {
    let wanted=Set((ProcessInfo.processInfo.environment["MV_HOLD_PAIRS"] ?? "").split(separator:",").compactMap {Int($0)})
    let w=CVPixelBufferGetWidth(buffers[0]),h=CVPixelBufferGetHeight(buffers[0])
    let config=InterpolationConfig.fluid.fittingAspect(width:w,height:h),ww=config.workWidth,wh=config.workHeight
    let engine=try MotionCompensator(config:config)
    let spec=[LevelSpec(width:ww,height:wh,blockSize:config.blockSize,searchHalfPel:8,halfPelRefine:config.subpel,inheritFactor:4),
              LevelSpec(width:ww/2,height:wh/2,blockSize:16,searchHalfPel:16,halfPelRefine:false,inheritFactor:2),
              LevelSpec(width:ww/4,height:wh/4,blockSize:16,searchHalfPel:32,halfPelRefine:false,inheritFactor:2),
              LevelSpec(width:ww/8,height:wh/8,blockSize:16,searchHalfPel:32,halfPelRefine:false,inheritFactor:1)]
    let forwardME=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:config.lambdaPx,smoothL0:true,gateL0:true,temporalGatePx:0)
    let reverseME=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:config.lambdaPx,smoothL0:true,gateL0:true,temporalGatePx:0)
    let dense=try DenseMotionPrototype(width:ww,height:wh,blockSize:config.blockSize,inverseSearch:true)
    let radius=Int(ProcessInfo.processInfo.environment["MV_HOLD_RADIUS"] ?? "6")!
    let low=Float(ProcessInfo.processInfo.environment["MV_HOLD_LOW"] ?? "0.2")!,high=Float(ProcessInfo.processInfo.environment["MV_HOLD_HIGH"] ?? "0.4")!
    func workLuma(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        var out=[UInt16](repeating:0,count:ww*wh)
        for y in 0..<wh {for x in 0..<ww {
            let x0=x*w/ww,x1=max(x0+1,(x+1)*w/ww),y0=y*h/wh,y1=max(y0+1,(y+1)*h/wh)
            var sum=0;for yy in y0..<y1 {let row=base.advanced(by:yy*stride).assumingMemoryBound(to:UInt16.self);for xx in x0..<x1 {sum+=Int(row[xx]>>6)}}
            out[y*ww+x]=UInt16(sum/((x1-x0)*(y1-y0)))
        }}
        return out.withUnsafeBytes {Data($0)}
    }
    func boxBlur(_ v: [Float]) -> [Float] {
        var tmp=v,out=v
        for y in 0..<wh {for x in 0..<ww {var s:Float=0,n:Float=0;for d in -radius...radius {let xx=x+d;if xx>=0,xx<ww {s+=v[y*ww+xx];n+=1}};tmp[y*ww+x]=s/n}}
        for y in 0..<wh {for x in 0..<ww {var s:Float=0,n:Float=0;for d in -radius...radius {let yy=y+d;if yy>=0,yy<wh {s+=tmp[yy*ww+x];n+=1}};out[y*ww+x]=s/n}}
        return out
    }
    func png(_ buffer: CVPixelBuffer,_ name: String) throws {try toneMappedPNG(buffer,output+"/"+name)}
    var rows=[[String:Any]]()
    for i in 0..<buffers.count-1 {
        let context: InterpolationTemporalContext? = i>0 && i+2<buffers.count ? InterpolationTemporalContext(before:buffers[i-1],after:buffers[i+2],beforeInterval:Float((pts[i]-pts[i-1])/(pts[i+1]-pts[i])),afterInterval:Float((pts[i+2]-pts[i+1])/(pts[i+1]-pts[i]))) : nil
        guard let current=engine.interpolatePair(I0:buffers[i],I1:buffers[i+1],tValues:[0.5],context:context).pixelBuffers.first else {continue}
        guard wanted.contains(i) else {continue}
        let a=workLuma(buffers[i]),b=workLuma(buffers[i+1])
        _=try forwardME.runPairBatched(cur:a,ref:b);let f=forwardME.downloadMV(level:0)
        _=try reverseME.runPairBatched(cur:b,ref:a);let r=reverseME.downloadMV(level:0)
        let result=try dense.interpolate(first:a,last:b,forward:f,backward:r,time:0.5)
        let density=boxBlur(result.reliability.map {$0<0.02 ? 1:0})
        let mask=density.map {v -> Float in let x=min(max((v-low)/(high-low),0),1);return x*x*(3-2*x)}
        func weight(_ fx: Float,_ fy: Float) -> Float {
            let x=min(max(fx-0.5,0),Float(ww-1)),y=min(max(fy-0.5,0),Float(wh-1)),x0=Int(x),y0=Int(y),x1=min(x0+1,ww-1),y1=min(y0+1,wh-1),ax=x-Float(x0),ay=y-Float(y0)
            return (mask[y0*ww+x0]*(1-ax)+mask[y0*ww+x1]*ax)*(1-ay)+(mask[y1*ww+x0]*(1-ax)+mask[y1*ww+x1]*ax)*ay
        }
        var held: CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary
        precondition(CVPixelBufferCreate(nil,w,h,CVPixelBufferGetPixelFormatType(current),attrs,&held)==kCVReturnSuccess)
        let out=held!;CVBufferPropagateAttachments(current,out)
        var maskView: CVPixelBuffer?;precondition(CVPixelBufferCreate(nil,w,h,CVPixelBufferGetPixelFormatType(current),attrs,&maskView)==kCVReturnSuccess)
        CVBufferPropagateAttachments(current,maskView!)
        for buffer in [current,buffers[i],out,maskView!] {CVPixelBufferLockBaseAddress(buffer,[])}
        var heldPixels=0
        for plane in 0..<2 {
            let pw=CVPixelBufferGetWidthOfPlane(out,plane),ph=CVPixelBufferGetHeightOfPlane(out,plane),channels=plane==0 ? 1:2
            func row(_ buffer: CVPixelBuffer,_ y: Int) -> UnsafeMutablePointer<UInt16> {CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)).assumingMemoryBound(to:UInt16.self)}
            for y in 0..<ph {
                let c=row(current,y),s=row(buffers[i],y),o=row(out,y),m=row(maskView!,y)
                for x in 0..<pw {
                    let k=weight((Float(x)+0.5)*Float(ww)/Float(pw),(Float(y)+0.5)*Float(wh)/Float(ph))
                    if plane==0 && k>0.01 {heldPixels+=1}
                    for ch in 0..<channels {
                        let j=x*channels+ch
                        o[j]=UInt16(Float(c[j]>>6)*(1-k)+Float(s[j]>>6)*k+0.5)<<6
                        m[j]=plane==0 ? UInt16(64+k*876)<<6 : 512<<6
                    }
                }
            }
        }
        for buffer in [current,buffers[i],out,maskView!] {CVPixelBufferUnlockBaseAddress(buffer,[])}
        try png(buffers[i],"pair\(i)-A.png");try png(buffers[i+1],"pair\(i)-B.png")
        try png(current,"pair\(i)-current.png");try png(out,"pair\(i)-hold.png");try png(maskView!,"pair\(i)-mask.png")
        let fraction=Double(heldPixels)/Double(w*h)
        rows.append(["pair":i,"PTS":[pts[i],pts[i+1]],"heldFraction":fraction])
        print("HOLD PREVIEW \(i): held \(String(format:"%.1f",100*fraction))% of frame")
    }
    try confidenceJSON(["radius":radius,"low":low,"high":high,"records":rows],output+"/hold-preview.json")
}

private let previewContext=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])

/// Approximate HDR→SDR half-size PNG for visual review only.
func toneMappedPNG(_ buffer: CVPixelBuffer,_ path: String) throws {
    var image=CIImage(cvPixelBuffer:buffer)
    if let map=CIFilter(name:"CIToneMapHeadroom") {map.setValue(image,forKey:kCIInputImageKey);map.setValue(8.0,forKey:"inputSourceHeadroom");map.setValue(1.0,forKey:"inputTargetHeadroom");image=map.outputImage ?? image}
    image=image.transformed(by:CGAffineTransform(scaleX:0.5,y:0.5))
    try previewContext.writePNGRepresentation(of:image,to:URL(fileURLWithPath:path),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
}
