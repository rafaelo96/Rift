import Foundation
import Interpolation
import CryptoKit

// Read-only bounded replay: source, ordinary Frame+, and F2. E2 stays disabled.
func runFramePlusScreenshotAudit(folder: String, output: String) throws {
    setenv("RIFT_E2", "0", 1)
    let m = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/manifest.json"))) as! [String: Any]
    let w=m["width"] as! Int, h=m["height"] as! Int, pts=m["sourcePTS"] as! [Double], hashes=m["sha256"] as! [String]
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    func frame(_ i: Int) throws -> Data {
        let data=try Data(contentsOf: URL(fileURLWithPath: folder+"/source_\(i).u16"))
        precondition(data.count == w*h*2 && SHA256.hash(data: data).map {String(format:"%02x",$0)}.joined() == hashes[i])
        return data
    }
    let levels=(0..<4).map { l in LevelSpec(width:w>>l,height:h>>l,blockSize:l==0 ? 8:16,searchHalfPel:l==0 ? 8:(l==1 ? 16:32),halfPelRefine:l==0,inheritFactor:l==0 ? 4:(l==3 ? 1:2)) }
    let search=try MotionSearchEngine(msl: motionShadersMSL,spec: levels,lambdaPx: 1,smoothL0: true,gateL0: true,temporalGatePx: 0)
    setenv("RIFT_FRAMEPLUS_F2","0",1)
    let ordinary=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    setenv("RIFT_FRAMEPLUS_F2","1",1)
    let filtered=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    var rows=[[String:Any]]()
    for span in [1,2] {
        for i in 0..<pts.count-span {
            let j=i+span,a=try frame(i),b=try frame(j)
            _=search.runPair(cur:a,ref:b);let f=search.downloadMV(level:0)
            _=search.runPair(cur:b,ref:a);let r=search.downloadMV(level:0)
            let context: DenseMotionPrototype.TemporalContext? = span==1 && i>0 && j+1<pts.count ? try .init(before:frame(i-1),after:frame(j+1),beforeInterval:Float((pts[i]-pts[i-1])/(pts[j]-pts[i])),afterInterval:Float((pts[j+1]-pts[j])/(pts[j]-pts[i]))) : nil
            let t:Float=span==1 ? 0.5 : Float((pts[i+1]-pts[i])/(pts[j]-pts[i]))
            let off=try ordinary.interpolate(first:a,last:b,forward:f,backward:r,times:[t],context:context)[0].pixels
            let on=try filtered.interpolate(first:a,last:b,forward:f,backward:r,times:[t],context:context)[0].pixels
            let truth: [UInt16]? = span==2 ? try frame(i+1).withUnsafeBytes {Array($0.bindMemory(to:UInt16.self))} : nil
            var changed=0,offError=0.0,onError=0.0
            for k in off.indices {
                if off[k] != on[k] {changed+=1}
                if let truth {offError+=Double(abs(Int(off[k])-Int(truth[k])));onError+=Double(abs(Int(on[k])-Int(truth[k])))}
            }
            rows.append(["span":span,"first":i,"PTS":[pts[i],pts[j]],"changedFraction":Double(changed)/Double(w*h),"offMAE":truth == nil ? -1:offError/Double(w*h),"onMAE":truth == nil ? -1:onError/Double(w*h)])
            // Keep every comparison lossless; no selection of favorable frames.
            let name="span\(span)-pair\(i)"
            confidencePNG(off,w,h,output+"/\(name)-off.png")
            confidencePNG(on,w,h,output+"/\(name)-on.png")
            if let truth {confidencePNG(truth,w,h,output+"/\(name)-truth.png")}
            if span==1 {confidencePNG(a.withUnsafeBytes {Array($0.bindMemory(to:UInt16.self))},w,h,output+"/source-\(i).png")}
        }
    }
    try confidenceJSON(["width":w,"height":h,"E2":false,"staticGuard":ProcessInfo.processInfo.environment["RIFT_STATIC_MOTION_GUARD"] == "1","records":rows,"scope":"Bounded work-plane luma replay; no native color, Strong, display or performance validation"],output+"/metrics.json")
}
