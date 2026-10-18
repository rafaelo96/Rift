import Foundation
import Interpolation
import CryptoKit

func runEdgeFieldDiagnostic() throws {
    let env=ProcessInfo.processInfo.environment,out=env["MV_F2_OUTPUT"]!,phase=env["MV_F2_PHASE"] ?? "quality",enabled=env["MV_F2_EDGE_REGULARIZE"]=="1"
    precondition(env["RIFT_E2"] != "1" && env["RIFT_STATIC_MOTION_GUARD"]=="1","E2 must stay off; preserve approved static protection")
    setenv("RIFT_PAIR_CONFIDENCE","0",1);setenv("RIFT_DENSE_ORACLE","1",1)
    try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
    if phase=="synthetic" {
        let w=48,h=32,filter=try EdgeFieldRegularizer(width:w,height:h),flat=Array(repeating:UInt16(500),count:w*h).withUnsafeBytes{Data($0)}
        for dx:Float in [0,4] {
            let f=Array(repeating:SIMD4<Float>(dx,0,0.7,2),count:w*h);let r=try filter.apply(f,source:flat);precondition(f==r,"Uniform motion must remain exactly unchanged")
        }
        var f=Array(repeating:SIMD4<Float>(4,0,0.7,2),count:w*h)
        for y in 8..<16 {for x in 16..<24 {f[y*w+x].x=20}}
        let r=try filter.apply(f,source:flat);precondition(r[12*w+20].x==4,"Same-surface outlier should be removed")
        let a=(0..<w*h).map{UInt16($0%w<24 ? 100:900)}.withUnsafeBytes{Data($0)}
        let edge=(0..<w*h).map{SIMD4<Float>($0%w<24 ? 4:-4,0,0.7,2)};let edgeResult=try filter.apply(edge,source:a);precondition(edgeResult==edge,"Strong edge must not mix surfaces")
        try confidenceJSON(["uniformStaticExact":true,"uniformPan4pxExact":true,"sameSurfaceOutlierRemoved":true,"luminanceDiscontinuityPreserved":true,"metadataUnchanged":true],out+"/synthetic.json");print("F2 synthetic controls passed");return
    }
    let folder=env["MV_F2_WINDOW"]!,manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:folder+"/manifest.json"))) as! [String:Any]
    let w=manifest["width"] as! Int,h=manifest["height"] as! Int,pts=manifest["sourcePTS"] as! [Double],hashes=manifest["sha256"] as! [String]
    func frame(_ i:Int)throws->Data{let a=try Data(contentsOf:URL(fileURLWithPath:folder+"/source_\(i).u16"));precondition(SHA256.hash(data:a).map{String(format:"%02x",$0)}.joined()==hashes[i]);return a}
    let levels=(0..<4).map{l in LevelSpec(width:w>>l,height:h>>l,blockSize:l==0 ? 8:16,searchHalfPel:l==0 ? 8:(l==1 ? 16:32),halfPelRefine:l==0,inheritFactor:l==0 ? 4:(l==3 ? 1:2))}
    let search=try MotionSearchEngine(msl:motionShadersMSL,spec:levels,lambdaPx:1,smoothL0:true,gateL0:true,temporalGatePx:0),dense=try DenseMotionPrototype(width:w,height:h,inverseSearch:true),plain=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    let filter=enabled ? try EdgeFieldRegularizer(width:w,height:h):nil
    var records=[[String:Any]](),movements=[Float]()
    let span=phase=="quality" ? 2:1,indices=phase=="quality" ? [4]:Array(0..<48)
    for i in indices {
        let j=i+span,a=try frame(i),b=try frame(j)
        let available=i>0 && j+1<pts.count
        let context:DenseMotionPrototype.TemporalContext? = span==1 && available ? try .init(before:frame(i-1),after:frame(j+1),beforeInterval:Float((pts[i]-pts[i-1])/(pts[j]-pts[i])),afterInterval:Float((pts[j+1]-pts[j])/(pts[j]-pts[i]))):nil
        let times:[Float]=phase=="quality" ? [Float((pts[i+1]-pts[i])/(pts[j]-pts[i]))]:[0.25,0.5,0.75]
        var meEnd:UInt64=0,regEnd:UInt64=0,originalF=[SIMD4<Float>](),originalR=[SIMD4<Float>](),filteredF=[SIMD4<Float>]()
        dense.diagnosticFlowOverride={f,r in
            meEnd=DispatchTime.now().uptimeNanoseconds
            let ff=try! filter?.apply(f,source:a) ?? f,rr=try! filter?.apply(r,source:b) ?? r
            regEnd=DispatchTime.now().uptimeNanoseconds
            originalF=f;originalR=r;filteredF=ff
            return(ff,rr)
        }
        let start=DispatchTime.now().uptimeNanoseconds
        _=search.runPair(cur:a,ref:b);let f=search.downloadMV(level:0);_=search.runPair(cur:b,ref:a);let r=search.downloadMV(level:0)
        let result=try dense.interpolate(first:a,last:b,forward:f,backward:r,times:times,context:context)
        let end=DispatchTime.now().uptimeNanoseconds
        precondition(meEnd>=start && regEnd>=meEnd && end>=regEnd)
        let me=Double(meEnd-start)/1e6,reg=Double(regEnd-meEnd)/1e6,synth=Double(end-regEnd)/1e6,total=Double(end-start)/1e6
        precondition(abs(me+reg+synth-total)<1e-8)
        records.append(["first":i,"span":span,"enabled":enabled,"MEms":me,"regularizationMS":reg,"synthesisMS":synth,"totalMS":total,"subframes":times.count,"PTS":[pts[i],pts[j]],"crossesCut":folder.contains("anime1082") && span==1 && i==6])
        if phase=="quality" {
            let baseline=try plain.interpolate(first:a,last:b,forward:f,backward:r,times:times,context:context)
            if !enabled {precondition(baseline[0].pixels==result[0].pixels && baseline[0].forward==result[0].forward && baseline[0].backward==result[0].backward,"Disabled output differs from ordinary engine")}
            precondition(originalF==baseline[0].forward && originalR==baseline[0].backward,"Filter input must equal ordinary final field")
            confidencePNG(result[0].pixels,w,h,out+"/prediction.png");confidencePNG(baseline[0].pixels,w,h,out+"/ordinary.png");confidencePNG(try frame(i+1).withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))},w,h,out+"/truth.png")
            try result[0].pixels.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:out+"/prediction.u16"))
        }
        if phase=="quality" || phase=="motion" {
            for y in stride(from:4,to:h,by:8){for x in stride(from:4,to:w,by:8){let k=y*w+x;movements += [Float(i),Float(x),Float(y),originalF[k].x,originalF[k].y,filteredF[k].x,filteredF[k].y]}}
        }
    }
    if !movements.isEmpty {try movements.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:out+"/block-motion.f32"))}
    try confidenceJSON(["phase":phase,"enabled":enabled,"width":w,"height":h,"records":records,"timingScope":"Offline work-plane wall times including diagnostic readback/reupload. ME includes seed searches and dense estimation; synthesis includes projection, luma synthesis and result readback; excludes decode, native color and Strong.","identityOrdinary":phase=="quality" && !enabled,"E2":false],out+"/metrics.json")
    print("F2 \(phase) enabled=\(enabled): \(records.count) pairs, \(out)")
}
