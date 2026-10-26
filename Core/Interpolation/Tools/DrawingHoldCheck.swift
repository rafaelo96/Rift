import Foundation
import CoreVideo
import Interpolation

// Frame+ drawing hold: inside a pan, a region redrawn with unrelated content
// must show the nearest source frame; a rigid pan alone must stay byte-identical
// to RIFT_DRAWING_HOLD=0.
func checkDrawingHold() throws {
    let w=1024,h=432,box=(x:400,y:120,w:220,h:200)
    func image(_ shift: Int,_ redraw: Double?) -> CVPixelBuffer {
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
                        value=512+180*sin(u*0.031+v*0.017)+140*sin(v*0.043-u*0.011+1)+90*sin((u+v)*0.07)
                        if let seed=redraw,x>=box.x,x<box.x+box.w,y>=box.y,y<box.y+box.h {
                            let s=Double(x),t=Double(y)
                            value=512+260*sin(s*0.09*seed+t*0.05)+200*sin(t*0.11/seed-s*0.03+seed)
                        }
                    }
                    row[x]=UInt16(max(64,min(940,value)))<<6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[]);return buffer
    }
    func luma(_ buffer: CVPixelBuffer) -> [UInt16] {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        return (0..<h).flatMap {y in (0..<w).map {base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)[$0]}}
    }
    let config=InterpolationConfig.fluid.fittingAspect(width:w,height:h)
    // Default configuration holds; the maximum-fluidity mode turns it off by config.
    guard config.usesDrawingHold else {print("DRAWING HOLD CHECK FAILED: default config does not hold");exit(3)}
    let off=try MotionCompensator(config:InterpolationConfig(workWidth:config.workWidth,workHeight:config.workHeight,usesDrawingHold:false))
    let on=try MotionCompensator(config:config)
    let a=image(0,nil),pan=image(12,nil)
    let panOnResult=on.interpolatePair(I0:a,I1:pan,tValues:[0.5]).pixelBuffers,panOffResult=off.interpolatePair(I0:a,I1:pan,tValues:[0.5]).pixelBuffers
    let panOn=luma(panOnResult[0]),panOff=luma(panOffResult[0])
    let panChanged=zip(panOn,panOff).filter {$0 != $1}.count
    print("DRAWING HOLD: rigid pan pixels changed \(panChanged)")
    guard panChanged==0 else {print("DRAWING HOLD CHECK FAILED: rigid pan changed");exit(3)}
    on.resetTemporalState();off.resetTemporalState()
    let a2=image(0,1.0),b2=image(12,2.7),src=luma(a2)
    let held=luma(on.interpolatePair(I0:a2,I1:b2,tValues:[0.5]).pixelBuffers[0]),plain=luma(off.interpolatePair(I0:a2,I1:b2,tValues:[0.5]).pixelBuffers[0])
    func mad(_ x: [UInt16],_ y: [UInt16],inside: Bool) -> Double {
        var s=0.0,n=0.0
        for yy in 0..<h {for xx in 0..<w {
            let inBox=xx>=box.x+24 && xx<box.x+box.w-24 && yy>=box.y+24 && yy<box.y+box.h-24
            let outside=xx<box.x-80 || xx>=box.x+box.w+80 || yy<box.y-80 || yy>=box.y+box.h+80
            if inside ? inBox : outside {s+=abs(Double(x[yy*w+xx]>>6)-Double(y[yy*w+xx]>>6));n+=1}
        }}
        return s/n
    }
    let heldInside=mad(held,src,inside:true),plainInside=mad(plain,src,inside:true),outsideChange=mad(held,plain,inside:false)
    print("DRAWING HOLD: inside |held-I0| \(String(format:"%.2f",heldInside)) vs plain \(String(format:"%.2f",plainInside)); outside |held-plain| \(String(format:"%.3f",outsideChange))")
    guard heldInside<1 && plainInside>10 else {print("DRAWING HOLD CHECK FAILED: redrawn region not held");exit(3)}
    guard outsideChange<0.5 else {print("DRAWING HOLD CHECK FAILED: hold leaked into background");exit(3)}
    print("DRAWING HOLD: rigid pan byte-identical; redrawn region held; background untouched")
}

// Real-video A/B: the same sequential pairs through RIFT_DRAWING_HOLD=1 and =0.
func abDrawingHold(buffers: [CVPixelBuffer], pts: [Double], output: String) throws {
    let w=CVPixelBufferGetWidth(buffers[0]),h=CVPixelBufferGetHeight(buffers[0])
    let config=InterpolationConfig.fluid.fittingAspect(width:w,height:h)
    let off=try MotionCompensator(config:InterpolationConfig(workWidth:config.workWidth,workHeight:config.workHeight,usesDrawingHold:false))
    let on=try MotionCompensator(config:config)
    func luma(_ buffer: CVPixelBuffer) -> [UInt16] {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        var out=[UInt16](repeating:0,count:w*h)
        for y in 0..<h {let row=base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self);for x in 0..<w {out[y*w+x]=row[x]>>6}}
        return out
    }
    let wanted=Set((ProcessInfo.processInfo.environment["MV_HOLD_PAIRS"] ?? "").split(separator:",").compactMap {Int($0)})
    var rows=[[String:Any]](),onMS=[Double](),offMS=[Double]()
    for i in 0..<buffers.count-1 {
        let context: InterpolationTemporalContext? = i>0 && i+2<buffers.count ? InterpolationTemporalContext(before:buffers[i-1],after:buffers[i+2],beforeInterval:Float((pts[i]-pts[i-1])/(pts[i+1]-pts[i])),afterInterval:Float((pts[i+2]-pts[i+1])/(pts[i+1]-pts[i]))) : nil
        var start=DispatchTime.now().uptimeNanoseconds
        guard let x=on.interpolatePair(I0:buffers[i],I1:buffers[i+1],tValues:[0.5],context:context).pixelBuffers.first else {continue}
        onMS.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6);start=DispatchTime.now().uptimeNanoseconds
        guard let y=off.interpolatePair(I0:buffers[i],I1:buffers[i+1],tValues:[0.5],context:context).pixelBuffers.first else {continue}
        offMS.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        let source=x===buffers[i] || x===buffers[i+1]
        let a=luma(buffers[i]),b=luma(buffers[i+1]),p=source ? a:luma(x),q=source ? a:luma(y)
        var changed=0,farOn=0,farOff=0,moving=0
        for k in a.indices {
            if p[k] != q[k] {changed+=1}
            guard abs(Int(a[k])-Int(b[k]))>40 else {continue}
            moving+=1
            if min(abs(Int(p[k])-Int(a[k])),abs(Int(p[k])-Int(b[k])))>40 {farOn+=1}
            if min(abs(Int(q[k])-Int(a[k])),abs(Int(q[k])-Int(b[k])))>40 {farOff+=1}
        }
        if wanted.contains(i) {try toneMappedPNG(x,output+"/pair\(i)-on.png");try toneMappedPNG(y,output+"/pair\(i)-off.png")}
        let n=Double(w*h)
        rows.append(["pair":i,"PTS":[pts[i],pts[i+1]],"sourceFallback":source,"changedFraction":Double(changed)/n,"farOn":Double(farOn)/n,"farOff":Double(farOff)/n,"movingFraction":Double(moving)/n])
        print("HOLD AB \(i): changed \(String(format:"%.2f",100*Double(changed)/n))% far \(String(format:"%.2f",100*Double(farOff)/n))% -> \(String(format:"%.2f",100*Double(farOn)/n))%")
    }
    func median(_ v: [Double]) -> Double {v.isEmpty ? 0 : v.sorted()[v.count/2]}
    try confidenceJSON(["records":rows,"medianPairMSOn":median(onMS),"medianPairMSOff":median(offMS)],output+"/hold-ab.json")
    print("HOLD AB timing: median pair \(String(format:"%.2f",median(onMS))) ms on vs \(String(format:"%.2f",median(offMS))) ms off")
}
