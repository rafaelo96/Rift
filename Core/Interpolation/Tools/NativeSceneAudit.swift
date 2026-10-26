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
    if ProcessInfo.processInfo.environment["MV_HOLD_CALIBRATION"]=="1" {
        try calibrateDrawingHold(lumas:buffers.map(luma),w:w,h:h,pts:pts,output:output);return
    }
    if ProcessInfo.processInfo.environment["MV_CUT_FEATURES"]=="1" {
        try auditCutFeatures(lumas:buffers.map(luma),w:w,h:h,pts:pts,output:output);return
    }
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
        let fast=ProcessInfo.processInfo.environment["MV_NATIVE_SCENE_FAST"]=="1"
        let midHash=pixels.withUnsafeBytes {SHA256.hash(data:$0).map {String(format:"%02x",$0)}.joined()}
        let single=fast ? batch : engine.interpolatePair(I0:buffers[i],I1:buffers[i+1],tValues:[0.5],context:context).pixelBuffers
        let singlePixels=fast ? pixels : luma(single[0]);let changed=zip(pixels,singlePixels).filter{$0 != $1}.count
        // Far-from-both: generated luma differs from BOTH sources by more than 40/1023
        // where the sources themselves differ (moving content). Mask: white = far.
        let a=luma(buffers[i]),b=luma(buffers[i+1]),limit=40
        var far=0,moving=0,mask=[UInt16](repeating:0,count:w*h)
        for k in pixels.indices where abs(Int(a[k])-Int(b[k]))>limit {
            moving+=1
            let g=Int(pixels[k])
            if min(abs(g-Int(a[k])),abs(g-Int(b[k])))>limit {far+=1;mask[k]=1023}
        }
        rows.append(["first":i,"PTS":[pts[i],pts[i+1]],"batchSingleChanged":changed,"midpointIsSource":batch[1] === buffers[i],"quarterIsSource":batch[0] === buffers[i],
                     "farFraction":Double(far)/Double(w*h),"farOfMoving":moving==0 ? 0:Double(far)/Double(moving),"movingFraction":Double(moving)/Double(w*h),"midHash":midHash])
        if fast {continue}
        confidencePNG(mask,w,h,output+"/pair\(i)-far.png")
        print("NATIVE SCENE \(i): far \(String(format:"%.3f",100*Double(far)/Double(w*h)))% of frame, \(String(format:"%.1f",moving==0 ? 0:100*Double(far)/Double(moving)))% of moving")
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

// Scene-cut calibration only: per consecutive pair, luma statistics on a ~1/3
// decimated plane (close to the 1152x480 work plane). No interpolation runs.
func auditCutFeatures(lumas: [[UInt16]], w: Int, h: Int, pts: [Double], output: String) throws {
    let step=3,dw=w/step,dh=h/step,bins=64,grid=4
    let small=lumas.map { l -> [UInt16] in
        var s=[UInt16](repeating:0,count:dw*dh)
        for y in 0..<dh {for x in 0..<dw {s[y*dw+x]=l[y*step*w+x*step]}}
        return s
    }
    func histogram(_ s: [UInt16],_ x0: Int,_ x1: Int,_ y0: Int,_ y1: Int) -> [Double] {
        var hist=[Double](repeating:0,count:bins)
        for y in y0..<y1 {for x in x0..<x1 {hist[min(Int(s[y*dw+x])*bins/1024,bins-1)]+=1}}
        let n=Double((x1-x0)*(y1-y0));return hist.map {$0/n}
    }
    func l1(_ a: [Double],_ b: [Double]) -> Double {zip(a,b).reduce(0) {$0+abs($1.0-$1.1)}}
    // Motion-compensated residual on ME level 1, as Frame+ production would see it:
    // work-plane luma (area downscale, 0...1023), production pyramid, forward L1 vectors.
    let config=InterpolationConfig.fluid.fittingAspect(width:w,height:h),ww=config.workWidth,wh=config.workHeight
    let spec=[LevelSpec(width:ww,height:wh,blockSize:config.blockSize,searchHalfPel:8,halfPelRefine:config.subpel,inheritFactor:4),
              LevelSpec(width:ww/2,height:wh/2,blockSize:16,searchHalfPel:16,halfPelRefine:false,inheritFactor:2),
              LevelSpec(width:ww/4,height:wh/4,blockSize:16,searchHalfPel:32,halfPelRefine:false,inheritFactor:2),
              LevelSpec(width:ww/8,height:wh/8,blockSize:16,searchHalfPel:32,halfPelRefine:false,inheritFactor:1)]
    let forward=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:config.lambdaPx,smoothL0:true,gateL0:true,temporalGatePx:0)
    let reverse=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:config.lambdaPx,smoothL0:true,gateL0:true,temporalGatePx:0)
    func work(_ l: [UInt16]) -> Data {
        var out=[UInt16](repeating:0,count:ww*wh)
        for y in 0..<wh {for x in 0..<ww {
            let x0=x*w/ww,x1=max(x0+1,(x+1)*w/ww),y0=y*h/wh,y1=max(y0+1,(y+1)*h/wh)
            var sum=0;for yy in y0..<y1 {for xx in x0..<x1 {sum+=Int(l[yy*w+xx])}}
            out[y*ww+x]=UInt16(sum/((x1-x0)*(y1-y0)))
        }}
        return out.withUnsafeBytes {Data($0)}
    }
    let works=lumas.map(work)
    var residuals=[[String:Any]]()
    for i in 0..<works.count-1 {
        _=try forward.runPairBatched(cur:works[i],ref:works[i+1]);_=try reverse.runPairBatched(cur:works[i+1],ref:works[i])
        let a=forward.readLevel(1),b=reverse.readLevel(1),mv=forward.downloadMV(level:1),g=forward.grids[1],lw=ww/2,lh=wh/2
        var signed=[[Double]](repeating:[],count:3)
        for by in 0..<g.h {for bx in 0..<g.w {
            let v=mv[by*g.w+bx]
            for (s,sign) in [0,1,-1].enumerated() {
                let dx=Int(v.x)*sign/2,dy=Int(v.y)*sign/2;var sum=0,n=0
                for y in by*16..<min(by*16+16,lh) {for x in bx*16..<min(bx*16+16,lw) {
                    let rx=min(max(x+dx,0),lw-1),ry=min(max(y+dy,0),lh-1)
                    sum+=abs(Int(a[y*lw+x])-Int(b[ry*lw+rx]));n+=1
                }}
                signed[s].append(Double(sum)/Double(max(n,1)))
            }
        }}
        func summary(_ r: [Double]) -> [String:Any] {
            let sorted=r.sorted()
            return ["median":sorted[sorted.count/2],"p25":sorted[sorted.count/4],
                    "over":[16,24,32,48,64,96].map {t in Double(r.filter {$0>Double(t)}.count)/Double(r.count)}]
        }
        residuals.append(["zero":summary(signed[0]),"plus":summary(signed[1]),"minus":summary(signed[2]),"blocks":signed[0].count])
    }
    var rows=[[String:Any]]()
    for i in 0..<small.count-1 {
        let a=small[i],b=small[i+1]
        var mad=0.0
        for k in a.indices {mad+=Double(abs(Int(a[k])-Int(b[k])))}
        var cells=[Double]()
        for gy in 0..<grid {for gx in 0..<grid {
            let x0=gx*dw/grid,x1=(gx+1)*dw/grid,y0=gy*dh/grid,y1=(gy+1)*dh/grid
            cells.append(l1(histogram(a,x0,x1,y0,y1),histogram(b,x0,x1,y0,y1)))
        }}
        cells.sort()
        rows.append(["pair":i,"PTS":[pts[i],pts[i+1]],"residual":residuals[i],"histL1":l1(histogram(a,0,dw,0,dh),histogram(b,0,dw,0,dh)),
                     "cellL1Median":(cells[7]+cells[8])/2,"cellL1Min":cells[0],"mad":mad/Double(a.count)])
    }
    let tw=w/8,th=h/8
    for (i,l) in lumas.enumerated() {
        var t=[UInt16](repeating:0,count:tw*th)
        for y in 0..<th {for x in 0..<tw {t[y*tw+x]=l[y*8*w+x*8]}}
        confidencePNG(t,tw,th,output+"/thumb\(String(format:"%03d",i)).png")
    }
    try confidenceJSON(["width":w,"height":h,"decimation":step,"bins":bins,"grid":grid,"records":rows],output+"/cut-features.json")
    print("CUT FEATURES: \(rows.count) pairs")
}
