import Foundation
import Interpolation
import Metal
import CryptoKit

func replayE2Diagnostic(folder: String) throws {
    let env=ProcessInfo.processInfo.environment,out=env["MV_E2_OUTPUT"]!,clip=env["MV_E2_CLIPS"]=="1"
    precondition(env["RIFT_STATIC_MOTION_GUARD"]=="1")
    try FileManager.default.createDirectory(atPath: out,withIntermediateDirectories: true)
    let manifest=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:folder+"/manifest.json"))) as! [String:Any]
    let w=manifest["width"] as! Int,h=manifest["height"] as! Int,pts=manifest["sourcePTS"] as! [Double],hashes=manifest["sha256"] as! [String],gw=(w+7)/8,gh=(h+7)/8
    func frame(_ i:Int)throws->Data {let data=try Data(contentsOf:URL(fileURLWithPath:"\(folder)/source_\(i).u16"));precondition(data.count==w*h*2 && SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()==hashes[i]);return data}
    let levels=(0..<4).map{l in LevelSpec(width:w>>l,height:h>>l,blockSize:l==0 ? 8:16,searchHalfPel:l==0 ? 8:(l==1 ? 16:32),halfPelRefine:l==0,inheritFactor:l==0 ? 4:(l==3 ? 1:2))}
    let search=try MotionSearchEngine(msl:motionShadersMSL,spec:levels,lambdaPx:1,smoothL0:true,gateL0:true,temporalGatePx:0)
    setenv("RIFT_E2","0",1);let baseline=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    setenv("RIFT_E2","1",1);let candidate=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    let offWriter=clip ? try E2VideoWriter(path:out+"/off.mp4",width:w,height:h):nil,onWriter=clip ? try E2VideoWriter(path:out+"/on.mp4",width:w,height:h):nil
    var records=[[String:Any]](),allRows=[Float](),tick=0
    for span in (clip ? [1]:[1,2]) {
        candidate.resetLocalConfidenceState()
        for i in 0..<pts.count-span {
            let j=i+span,a=try frame(i),b=try frame(j)
            _=search.runPair(cur:a,ref:b);let f=search.downloadMV(level:0);_=search.runPair(cur:b,ref:a);let r=search.downloadMV(level:0)
            let available=i>0 && j+1<pts.count
            var temporal=[SIMD4<Float>](repeating:SIMD4(repeating:.nan),count:gw*gh)
            if available {
                _=search.runPair(cur:a,ref:try frame(i-1));let previous=search.downloadMV(level:0)
                _=search.runPair(cur:b,ref:try frame(j+1));let next=search.downloadMV(level:0)
                let bs=Float((pts[j]-pts[i])/(pts[i]-pts[i-1]))/(-2),fs=Float((pts[j]-pts[i])/(pts[j+1]-pts[j]))/(-2)
                for k in temporal.indices {temporal[k]=SIMD4(Float(previous[k].x)*bs,Float(previous[k].y)*bs,Float(next[k].x)*fs,Float(next[k].y)*fs)}
            }
            candidate.diagnosticTemporalVectors=temporal
            candidate.localConfidenceHistoryStep=span==1 ? 1:Float((pts[i+1]-pts[i])/(pts[j]-pts[i]))
            let context:DenseMotionPrototype.TemporalContext? = span==1 && available ? try .init(before:frame(i-1),after:frame(j+1),beforeInterval:Float((pts[i]-pts[i-1])/(pts[j]-pts[i])),afterInterval:Float((pts[j+1]-pts[j])/(pts[j]-pts[i]))):nil
            var times:[Float]
            if clip {
                times=[]
                while tick<600 && Double(tick)/60+pts[0]<pts[j]-1e-7 {
                    let time=Float((Double(tick)/60+pts[0]-pts[i])/(pts[j]-pts[i]));if time>=0 {times.append(time)};tick+=1
                }
                if times.isEmpty {if tick>=600 {break};continue}
                precondition(times.count<=4,"Source cadence exceeds supported diagnostic subframe batch")
            } else {times=span==1 ? [0.25,0.5,0.75]:[Float((pts[i+1]-pts[i])/(pts[j]-pts[i]))]}
            let before=try baseline.interpolate(first:a,last:b,forward:f,backward:r,times:times,context:context)
            let after=try candidate.interpolate(first:a,last:b,forward:f,backward:r,times:times,context:context)
            var map=[SIMD4<Float>](repeating:.zero,count:w*h)
            map.withUnsafeMutableBytes {candidate.localDegradationMap!.getBytes($0.baseAddress!,bytesPerRow:w*16,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)}
            var changed=0
            for sample in times.indices {
                for k in 0..<w*h {
                    if map[k].x==0 {precondition(before[sample].pixels[k]==after[sample].pixels[k],"Trusted pixel changed")}
                    if before[sample].pixels[k] != after[sample].pixels[k] {changed+=1}
                }
                if clip {try offWriter!.append(before[sample].pixels);try onWriter!.append(after[sample].pixels)}
            }
            let truth:[UInt16]? = span==2 ? try frame(i+1).withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))}:nil
            let center=span==1 ? min(1,times.count-1):0
            var beforeError=0.0,afterError=0.0,degradedBefore=0.0,degradedAfter=0.0,trustedBefore=0.0,trustedAfter=0.0,degradedCount=0,trustedCount=0
            for yy in 0..<gh {for xx in 0..<gw {
                var weights:Float=0,marked=0,eb:Float=0,ea:Float=0
                for y in yy*8..<min(h,yy*8+8) {for x in xx*8..<min(w,xx*8+8) {
                    let k=y*w+x;weights+=map[k].x;if map[k].x>0 {marked+=1}
                    if let truth {
                        let be=Double(abs(Int(before[center].pixels[k])-Int(truth[k]))),ae=Double(abs(Int(after[center].pixels[k])-Int(truth[k])));eb+=Float(be);ea+=Float(ae);beforeError+=be;afterError+=ae
                        if map[k].x>0 {degradedBefore+=be;degradedAfter+=ae;degradedCount+=1}else{trustedBefore+=be;trustedAfter+=ae;trustedCount+=1}
                    }
                }}
                allRows += [Float(span),Float(i),weights/64,Float(marked)/64,truth==nil ? .nan:eb/64,truth==nil ? .nan:ea/64]
            }}
            let marked=map.filter{$0.x>0}.count
            records.append(["span":span,"first":i,"PTS":[pts[i],pts[j]],"markedPixelFraction":Double(marked)/Double(w*h),"actualChangedFraction":Double(changed)/Double(w*h*times.count),"beforeMAE":truth==nil ? -1:beforeError/Double(w*h),"afterMAE":truth==nil ? -1:afterError/Double(w*h),"degradedBeforeMAE":degradedCount==0 ? -1:degradedBefore/Double(degradedCount),"degradedAfterMAE":degradedCount==0 ? -1:degradedAfter/Double(degradedCount),"trustedBeforeMAE":trustedCount==0 ? -1:trustedBefore/Double(trustedCount),"trustedAfterMAE":trustedCount==0 ? -1:trustedAfter/Double(trustedCount),"trustedPixels":trustedCount,"degradedPixels":degradedCount,"samples":times.count])
            if i==4 || i==30 || (clip && i % 24 == 0) {
                let name="span\(span)-pair\(i)";confidencePNG(before[center].pixels,w,h,"\(out)/\(name)-before.png");confidencePNG(after[center].pixels,w,h,"\(out)/\(name)-after.png")
                confidencePNG(a.withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))},w,h,"\(out)/\(name)-A.png");confidencePNG(b.withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))},w,h,"\(out)/\(name)-B.png")
                if let truth {confidencePNG(truth,w,h,"\(out)/\(name)-truth.png")}
                try map.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:"\(out)/\(name)-weights.f32"))
            }
        }
    }
    if clip {precondition(offWriter!.count==600 && onWriter!.count==600);try offWriter!.finish();try onWriter!.finish()}
    try allRows.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:out+"/block-errors.f32"))
    try confidenceJSON(["width":w,"height":h,"clipFrames":offWriter?.count ?? 0,"records":records,"blockFields":["span","first","meanWeight","markedFraction","beforeMAE10bit","afterMAE10bit"],"trustedPixelIdentity":true,"thresholds":"E1 top5 enter, top2 full, top10 exit; revised after initial face ROI max score 0.94314 stayed below top2"],out+"/metrics.json")
    print("E2 REPLAY \(out): \(records.count) pairs; trusted identity passed")
}

func checkE2Stationary() throws {
    let out=ProcessInfo.processInfo.environment["MV_E2_OUTPUT"]!;try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
    let w=96,h=64,n=w*h,seeds=Array(repeating:SIMD2<Int32>(0,0),count:n/64)
    setenv("RIFT_DENSE_ORACLE","1",1);setenv("RIFT_E2","0",1);let off=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    setenv("RIFT_E2","1",1);let on=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    var rows=[[String:Any]]()
    let cases:[(String,Bool,Int)]=[("texture",false,0),("texture",false,1),("texture",true,0),("texture",true,1)]+["flat","gradient","quantized-noise","edge"].flatMap{p in [(p,true,0),(p,true,1)]}
    for (profile,moving,noise) in cases {
        let a=(0..<n).map{i->UInt16 in
            let x=i%w,y=i/w;var value:Float=0.55
            if profile=="texture" {value+=0.012*cos(Float(x)*Float.pi/4)+0.004*sin(Float(y)*0.37)}
            if profile=="gradient" {value=0.5+Float(x)*0.0003+Float(y)*0.0001}
            if profile=="edge" {value=0.5+(x<w/2 ? 0:0.004)}
            if profile=="quantized-noise" {var v=UInt32(i)&*1664525&+1013904223;v ^= v>>13;value+=Float(Int(v%3)-1)/1023}
            return UInt16((value*1023).rounded())
        }
        let b=a.enumerated().map{UInt16(Int($0.element)+($0.offset%2==0 ? noise:-noise))}
        let f=Array(repeating:SIMD4<Float>(moving ? 4:0,0,1,0),count:n),r=Array(repeating:SIMD4<Float>(moving ? -4:0,0,1,0),count:n)
        off.diagnosticFlowOverride={_,_ in(f,r)};on.diagnosticFlowOverride={_,_ in(f,r)};on.diagnosticTemporalVectors=Array(repeating:SIMD4<Float>(moving ? 4:0,0,moving ? -4:0,0),count:n/64);on.resetLocalConfidenceState()
        let aa=a.withUnsafeBytes{Data($0)},bb=b.withUnsafeBytes{Data($0)}
        let baseline=try off.interpolate(first:aa,last:bb,forward:seeds,backward:seeds,times:[0.25,0.5,0.75])
        let result=try on.interpolate(first:aa,last:bb,forward:seeds,backward:seeds,times:[0.25,0.5,0.75])
        var bad=0,count=0
        for sample in result.indices {for y in 8..<h-8 {for x in 8..<w-8 {let k=y*w+x;if abs(Int(result[sample].pixels[k])-Int(a[k]))>1 {bad+=1};count+=1}}}
        precondition(bad==0,"E2 stationary jitter")
        on.resetLocalConfidenceState();let repeated=try on.interpolate(first:aa,last:bb,forward:seeds,backward:seeds,times:[0.25,0.5,0.75]);precondition(zip(result,repeated).allSatisfy{$0.pixels==$1.pixels},"E2 reset was not deterministic")
        rows.append(["profile":profile,"wrongMovingField":moving,"noiseCodes":noise,"jitterFractionAbove1LSB":Double(bad)/Double(count),"resetIdentical":true,"baselineMidSHA":SHA256.hash(data:baseline[1].pixels.withUnsafeBytes{Data($0)}).map{String(format:"%02x",$0)}.joined()])
    }
    try confidenceJSON(rows,out+"/static-controls.json");print("E2 STATIC: twelve zero-jitter controls, repeated reset exact")
}
