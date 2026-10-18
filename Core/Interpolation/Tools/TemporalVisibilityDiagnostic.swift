import Foundation
import Interpolation
import CryptoKit

func replayTemporalVisibility(folder: String,output: String) throws {
    let env=ProcessInfo.processInfo.environment,enabled=env["MV_VISIBILITY_RECONSTRUCT"]=="1"
    setenv("RIFT_E2","0",1);setenv("RIFT_FRAMEPLUS_F2","0",1);setenv("RIFT_PAIR_CONFIDENCE","0",1);setenv("RIFT_DENSE_ORACLE","0",1)
    let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:folder+"/manifest.json"))) as! [String:Any]
    let w=manifest["width"] as! Int,h=manifest["height"] as! Int,pts=manifest["sourcePTS"] as! [Double],hashes=manifest["sha256"] as! [String]
    precondition(w>=32 && h>=32 && w%32==0 && h%32==0 && pts.count<=49 && pts.count>=5 && hashes.count==pts.count && zip(pts,pts.dropFirst()).allSatisfy{$0<$1})
    let n=w*h,renderer=TemporalVisibility(width:w,height:h),cuts=Set((env["MV_VISIBILITY_CUTS"] ?? "").split(separator:",").compactMap{Int($0)})
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    func frame(_ i:Int)throws->Data {
        let data=try Data(contentsOf:URL(fileURLWithPath:folder+"/source_\(i).u16"))
        precondition(data.count==n*2 && SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()==hashes[i])
        return data
    }
    func values(_ data:Data)->[Float] {data.withUnsafeBytes{$0.bindMemory(to:UInt16.self).map{Float($0)}}}
    func digest(_ data:[SIMD4<Float>])->String {data.withUnsafeBytes{SHA256.hash(data:Data($0)).map{String(format:"%02x",$0)}.joined()}}
    let levels=(0..<4).map{l in LevelSpec(width:w>>l,height:h>>l,blockSize:l==0 ? 8:16,searchHalfPel:l==0 ? 8:(l==1 ? 16:32),halfPelRefine:l==0,inheritFactor:l==0 ? 4:(l==3 ? 1:2))}
    func search()throws->MotionSearchEngine {try MotionSearchEngine(msl:motionShadersMSL,spec:levels,lambdaPx:1,smoothL0:true,gateL0:true,temporalGatePx:0)}
    let centralSearch=try search(),auxiliarySearch=try search()
    setenv("RIFT_DENSE_CANDIDATES","1",1);let central=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    setenv("RIFT_DENSE_CANDIDATES","0",1);let auxiliary=try DenseMotionPrototype(width:w,height:h,inverseSearch:true),plain=try DenseMotionPrototype(width:w,height:h,inverseSearch:true)
    var cache=[Int:VisibilityFields](),order=[Int](),searches=0
    func adjacent(_ i:Int)throws->VisibilityFields {
        if let value=cache[i] {return value}
        let a=try frame(i),b=try frame(i+1)
        _=auxiliarySearch.runPair(cur:a,ref:b);let f=auxiliarySearch.downloadMV(level:0)
        _=auxiliarySearch.runPair(cur:b,ref:a);let r=auxiliarySearch.downloadMV(level:0)
        let result=try auxiliary.interpolate(first:a,last:b,forward:f,backward:r,time:0.5)
        let value=VisibilityFields(forward:result.forward,backward:result.backward)
        cache[i]=value;order.append(i);searches+=1
        if order.count>4 {cache.removeValue(forKey:order.removeFirst())}
        precondition(cache.count<=4);return value
    }
    func crosses(_ a:Int,_ b:Int)->Bool {cuts.contains{a<=$0 && b>$0}}
    var records=[[String:Any]]()
    let spans=env["MV_VISIBILITY_SPAN"].flatMap(Int.init).map{[$0]} ?? [1,2]
    precondition(spans.allSatisfy{[1,2].contains($0)})
    let limit=env["MV_VISIBILITY_PAIRS"].flatMap(Int.init) ?? 48
    precondition((1...48).contains(limit))
    for span in spans {
        cache.removeAll();order.removeAll()
        for i in 0..<min(limit,pts.count-span) {
            let started=DispatchTime.now().uptimeNanoseconds,j=i+span,a=try frame(i),b=try frame(j),av=values(a),bv=values(b)
            let previous=i>0 ? try frame(i-1):nil,next=j+1<pts.count ? try frame(j+1):nil
            let beforeInterval=i>0 ? Float((pts[i]-pts[i-1])/(pts[j]-pts[i])):1,afterInterval=j+1<pts.count ? Float((pts[j+1]-pts[j])/(pts[j]-pts[i])):1
            let context:DenseMotionPrototype.TemporalContext? = span==1 && previous != nil && next != nil ? .init(before:previous!,after:next!,beforeInterval:beforeInterval,afterInterval:afterInterval):nil
            _=centralSearch.runPair(cur:a,ref:b);let seedF=centralSearch.downloadMV(level:0)
            _=centralSearch.runPair(cur:b,ref:a);let seedR=centralSearch.downloadMV(level:0)
            var decisions=[SIMD4<Float>]()
            central.diagnosticObserver={name,_,_,data in if name.hasSuffix("/decisions") {decisions=data}}
            let t:Float=span==1 ? 0.5:Float((pts[i+1]-pts[i])/(pts[j]-pts[i]))
            let base=try central.interpolate(first:a,last:b,forward:seedF,backward:seedR,times:[t],context:context)[0]
            precondition(decisions.count==n)
            if i==0 || i==4 {
                let ordinary=try plain.interpolate(first:a,last:b,forward:seedF,backward:seedR,times:[t],context:context)[0]
                precondition(base.pixels==ordinary.pixels && base.forward==ordinary.forward && base.backward==ordinary.backward,"Tracing changed ordinary baseline")
            }
            let centralSHA=[digest(base.forward),digest(base.backward)],cut=crosses(i,j)
            let heldBefore=previous.map{values($0).enumerated().reduce(Float(0)){$0+abs($1.element-av[$1.offset])}/Float(n)<=1} ?? true
            let heldAfter=next.map{values($0).enumerated().reduce(Float(0)){$0+abs($1.element-bv[$1.offset])}/Float(n)<=1} ?? true
            let useLeft=enabled && !cut && previous != nil && !heldBefore && !crosses(i-1,i)
            let useRight=enabled && !cut && next != nil && !heldAfter && !crosses(j,j+1)
            let left=useLeft ? try adjacent(i-1):nil,right=useRight ? try adjacent(j):nil
            if span==2 {precondition(i-1 != i+1 && j != i+1 && j+1 != i+1,"Hidden central frame leaked")}
            let renderStart=DispatchTime.now().uptimeNanoseconds
            let result=renderer.render(first:av,last:bv,before:useLeft ? values(previous!):nil,after:useRight ? values(next!):nil,forward:base.forward,backward:base.backward,left:left,right:right,baseline:base.pixels,decisions:decisions,t:t,beforeInterval:beforeInterval,afterInterval:afterInterval,enabled:enabled)
            let renderMS=Double(DispatchTime.now().uptimeNanoseconds-renderStart)/1e6
            let off=renderer.render(first:av,last:bv,before:nil,after:nil,forward:base.forward,backward:base.backward,left:nil,right:nil,baseline:base.pixels,decisions:decisions,t:t,enabled:false)
            precondition(off.pixels==base.pixels && centralSHA==[digest(base.forward),digest(base.backward)],"Disabled output/central fields changed")
            var states=Array(repeating:0,count:7),changed=0,selected=0
            for k in 0..<n {
                states[Int(result.states[k])]+=1
                if result.selected[k]>0 {selected+=1}
                if result.pixels[k] != base.pixels[k] {changed+=1;precondition(result.selected[k]>0)}
                if decisions[k].x>0.5 {precondition(result.pixels[k]==base.pixels[k],"Current static pixels changed")}
            }
            let name="span\(span)-pair\(i)"
            confidencePNG(base.pixels,w,h,output+"/\(name)-baseline.png");confidencePNG(result.pixels,w,h,output+"/\(name)-candidate.png")
            confidencePNG(av.map{UInt16($0)},w,h,output+"/\(name)-A.png");confidencePNG(bv.map{UInt16($0)},w,h,output+"/\(name)-B.png")
            confidencePNG(result.states.map{UInt16($0)*128},w,h,output+"/\(name)-states.png")
            confidencePNG(result.selected.map{UInt16($0)*1020},w,h,output+"/\(name)-selected.png")
            var row:[String:Any] = ["span":span,"first":i,"PTS":[pts[i],pts[j]],"t":t,"enabled":enabled,"crossesCut":cut,"heldBefore":heldBefore,"heldAfter":heldAfter,"leftEvidence":useLeft,"rightEvidence":useRight,"states":states,"selectedFraction":Double(selected)/Double(n),"changedFraction":Double(changed)/Double(n),"centralFieldSHA":centralSHA,"CPUreconstructionMS":renderMS,"offlinePairWallMS":Double(DispatchTime.now().uptimeNanoseconds-started)/1e6]
            if span==2 {
                let truth=try frame(i+1).withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))}
                confidencePNG(truth,w,h,output+"/\(name)-truth.png")
                var beforeError=0.0,afterError=0.0,selectedBefore=0.0,selectedAfter=0.0
                for k in 0..<n {let eb=Double(abs(Int(base.pixels[k])-Int(truth[k]))),ea=Double(abs(Int(result.pixels[k])-Int(truth[k])));beforeError+=eb;afterError+=ea;if result.selected[k]>0 {selectedBefore+=eb;selectedAfter+=ea}}
                row["MAE10bitBefore"]=beforeError/Double(n);row["MAE10bitAfter"]=afterError/Double(n)
                row["selectedMAE10bitBefore"]=selected>0 ? selectedBefore/Double(selected):-1;row["selectedMAE10bitAfter"]=selected>0 ? selectedAfter/Double(selected):-1
            }
            records.append(row)
            try confidenceJSON(["width":w,"height":h,"enabled":enabled,"records":records,"auxiliaryPairsEstimated":searches,"cacheMaxPairs":4,"stateNames":["untouched","A-only","B-only","paired","unsupported","ambiguous","static"],"sourceManifest":manifest,"E2":false,"scope":"Offline CPU luma reconstruction with diagnostic GPU analysis/readback; excludes native color, decode and Strong; not playback performance"],output+"/metrics.json")
            print("VISIBILITY \(name) selected=\(selected) changed=\(changed) cut=\(cut)")
        }
    }
}
