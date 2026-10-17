import Foundation
import Interpolation
import CryptoKit
import CoreGraphics
import ImageIO

func confidenceJSON(_ value: Any,_ path: String) throws {try JSONSerialization.data(withJSONObject: value,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))}
func confidencePNG(_ pixels: [UInt16],_ w: Int,_ h: Int,_ path: String) {
    let provider=CGDataProvider(data: Data(pixels.map {UInt8(clamping: Int($0)/4)}) as CFData)!
    let image=CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: w,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))
}

func replayConfidenceDiagnostic(folder: String) throws {
    let env=ProcessInfo.processInfo.environment
    precondition(env["RIFT_PAIR_CONFIDENCE"]=="1" && env["RIFT_STATIC_MOTION_GUARD"]=="1","Enable diagnostic and preserve reapplied static guard")
    let output=env["MV_CONFIDENCE_OUTPUT"]!
    try FileManager.default.createDirectory(atPath: output,withIntermediateDirectories: true)
    let manifest=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/manifest.json"))) as! [String:Any]
    let w=manifest["width"] as! Int,h=manifest["height"] as! Int,pts=manifest["sourcePTS"] as! [Double],hashes=manifest["sha256"] as! [String],gw=w/8,gh=h/8
    precondition(w%8==0 && h%8==0 && pts.count==49)
    func frame(_ i: Int) throws -> Data {
        let d=try Data(contentsOf: URL(fileURLWithPath: "\(folder)/source_\(i).u16"));precondition(d.count==w*h*2 && SHA256.hash(data: d).map {String(format: "%02x",$0)}.joined()==hashes[i]);return d
    }
    let specs=(0..<4).map {l in LevelSpec(width: w>>l,height: h>>l,blockSize: l==0 ? 8 : 16,searchHalfPel: l==0 ? 8 : (l==1 ? 16 : 32),halfPelRefine: l==0,inheritFactor: l==0 ? 4 : (l==3 ? 1 : 2))}
    let search=try MotionSearchEngine(msl: motionShadersMSL,spec: specs,lambdaPx: 1,smoothL0: true,gateL0: true,temporalGatePx: 0)
    let on=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    setenv("RIFT_PAIR_CONFIDENCE","0",1);let off=try DenseMotionPrototype(width: w,height: h,inverseSearch: true);setenv("RIFT_PAIR_CONFIDENCE","1",1)
    var offCalls=0;off.pairConfidenceObserver={_,_,_ in offCalls+=1}
    var records=[[String:Any]]()
    for span in [1,2] {
        for i in 0..<pts.count-span {
            let j=i+span,a=try frame(i),b=try frame(j)
            _=search.runPair(cur: a,ref: b);let f=search.downloadMV(level: 0)
            _=search.runPair(cur: b,ref: a);let r=search.downloadMV(level: 0)
            var temporal=[SIMD4<Float>](repeating: SIMD4(repeating: .nan),count: gw*gh)
            let available=i>0 && j+1<pts.count
            if available {
                _=search.runPair(cur: a,ref: try frame(i-1));let previous=search.downloadMV(level: 0)
                _=search.runPair(cur: b,ref: try frame(j+1));let next=search.downloadMV(level: 0)
                let beforeScale=Float((pts[j]-pts[i])/(pts[i]-pts[i-1]))/(-2),afterScale=Float((pts[j]-pts[i])/(pts[j+1]-pts[j]))/(-2)
                for k in temporal.indices {temporal[k]=SIMD4(Float(previous[k].x)*beforeScale,Float(previous[k].y)*beforeScale,Float(next[k].x)*afterScale,Float(next[k].y)*afterScale)}
            }
            on.diagnosticTemporalVectors=temporal;off.diagnosticTemporalVectors=temporal
            var calls=0,signals=[SIMD4<Float>]()
            on.pairConfidenceObserver={width,height,values in precondition(width==gw && height==gh);calls+=1;signals=values}
            let times: [Float]=span==1 ? [0.25,0.5,0.75] : [Float((pts[i+1]-pts[i])/(pts[j]-pts[i]))]
            // The hidden real central frame is never supplied as temporal context.
            let context: DenseMotionPrototype.TemporalContext? = span==1 && available ? try .init(before: frame(i-1),after: frame(j+1),beforeInterval: Float((pts[i]-pts[i-1])/(pts[j]-pts[i])),afterInterval: Float((pts[j+1]-pts[j])/(pts[j]-pts[i]))) : nil
            let baseline=try off.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
            let result=try on.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
            precondition(calls==1 && offCalls==0 && signals.count==gw*gh*2,"Signals must run once per pair only when enabled")
            for k in times.indices {precondition(baseline[k].pixels==result[k].pixels && baseline[k].forward==result[k].forward && baseline[k].backward==result[k].backward && baseline[k].mappingResidual==result[k].mappingResidual && baseline[k].reliability==result[k].reliability,"Read-only instrumentation changed output")}
            let name="span\(span)-pair\(i)"
            var rows=[Float]();rows.reserveCapacity(gw*gh*10)
            let truth: [UInt16]? = span==2 ? try frame(i+1).withUnsafeBytes {Array($0.bindMemory(to: UInt16.self))} : nil
            for y in 0..<gh {for x in 0..<gw {
                let block=y*gw+x,u=signals[2*block],v=signals[2*block+1]
                var error=Float.nan
                if let truth {
                    var sum: Float=0
                    for yy in y*8..<y*8+8 {for xx in x*8..<x*8+8 {let k=yy*w+xx;sum+=Float(abs(Int(truth[k])-Int(result[0].pixels[k])))}}
                    error=sum/64
                }
                rows += [u.x,u.y,u.z,u.w,v.x,v.y,v.z,v.w,error,Float(64)]
            }}
            try rows.withUnsafeBytes {Data($0)}.write(to: URL(fileURLWithPath: "\(output)/\(name).f32"))
            if i==4 || i==30 || (span==2 && (i==5 || i==6)) {
                let av=a.withUnsafeBytes {Array($0.bindMemory(to: UInt16.self))},bv=b.withUnsafeBytes {Array($0.bindMemory(to: UInt16.self))}
                confidencePNG(av,w,h,"\(output)/\(name)-A.png");confidencePNG(bv,w,h,"\(output)/\(name)-B.png")
                confidencePNG(result[span==1 ? 1 : 0].pixels,w,h,"\(output)/\(name)-prediction.png")
                if let truth {confidencePNG(truth,w,h,"\(output)/\(name)-truth.png")}
            }
            records.append(["name":name,"first":i,"last":j,"span":span,"PTS":[pts[i],pts[j]],"temporalAvailable":available,"signalCalls":calls,"identitySamples":times.count,"contextUsesHiddenFrame":false,"blockCount":gw*gh])
        }
    }
    try confidenceJSON(["width":w,"height":h,"blockSize":8,"fields":["fb_px","sad_texture","fold_fraction","inverse_px","temporal_px","AB_luma","texture_sigma","existing_risk","truth_MAE_10bit","pixels"],"records":records,"content":"animation; no live-action samples","guardEnabled":true],output+"/manifest.json")
    print("CONFIDENCE: \(output), \(records.count) pairs; once-per-pair and exact output identity passed")
}

func checkConfidenceDiagnostic() throws {
    let w=96,h=64,n=w*h,zeros=Array(repeating: SIMD2<Int32>(0,0),count: n/64)
    let image=Array(repeating: UInt16(512),count: n).withUnsafeBytes {Data($0)}
    setenv("RIFT_PAIR_CONFIDENCE","0",1);let off=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    setenv("RIFT_PAIR_CONFIDENCE","1",1);let on=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    on.diagnosticTemporalVectors=Array(repeating: .zero,count: n/64)
    var count=0
    on.pairConfidenceObserver={gw,gh,values in
        count+=1;precondition(gw==12 && gh==8 && values.count==n/32)
        for k in 0..<n/64 {let a=values[2*k],b=values[2*k+1];precondition(a == .zero && b.x==0 && b.y==0 && b.z==0,"Flat zero-motion signal must be zero")}
    }
    let times: [Float]=[0.25,0.5,0.75],a=try off.interpolate(first: image,last: image,forward: zeros,backward: zeros,times: times),b=try on.interpolate(first: image,last: image,forward: zeros,backward: zeros,times: times)
    precondition(count==1 && zip(a,b).allSatisfy {$0.pixels==$1.pixels && $0.forward==$1.forward && $0.backward==$1.backward},"Diagnostic identity/batch reuse failed")
    print("CONFIDENCE CHECK: flat signals zero, one computation for three subframes, exact disabled/enabled identity")
}
