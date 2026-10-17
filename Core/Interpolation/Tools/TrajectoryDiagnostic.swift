import Foundation
import Metal
import Interpolation
import CoreGraphics
import ImageIO
import CryptoKit

// Offline only. No changes to the playback pipeline or source movie.
private func trajectoryPNG(_ data: Data,_ w: Int,_ h: Int,_ path: String) throws {
    let gray=data.withUnsafeBytes { bytes in (0..<w*h).map { UInt8(clamping: Int(bytes.loadUnaligned(fromByteOffset: $0*2,as: UInt16.self))/4) } }
    let provider=CGDataProvider(data: Data(gray) as CFData)!
    let image=CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: w,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    guard let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,"public.png" as CFString,1,nil) else { throw NSError(domain: "TrajectoryPNG",code: 1) }
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "TrajectoryPNG",code: 2) }
}
private func trajectoryJSON(_ object: Any,_ path: String) throws {
    try JSONSerialization.data(withJSONObject: object,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
}
func exportTrajectoryWindow(frames: [Data],times: [Double],width: Int,height: Int,source: String,folder: String) throws {
    precondition(frames.count==times.count && (2...100).contains(frames.count))
    try FileManager.default.createDirectory(atPath: folder,withIntermediateDirectories: true)
    var hashes=[String]()
    for (i,frame) in frames.enumerated() {
        try frame.write(to: URL(fileURLWithPath: "\(folder)/source_\(i).u16"))
        hashes.append(SHA256.hash(data: frame).map { String(format: "%02x",$0) }.joined())
        if i%8==0 || i==frames.count-1 { try trajectoryPNG(frame,width,height,"\(folder)/source_\(i).png") }
    }
    try trajectoryJSON(["source":source,"sourcePTS":times,"width":width,"height":height,"sha256":hashes,
        "representation":"Original decoded luma resampled to the probe work plane, UInt16 little-endian 0...1023. PNG previews are 8-bit; no native HDR/color validation.",
        "duration":times.last!-times.first!,"engineRevision":ProcessInfo.processInfo.environment["MV_ENGINE_REVISION"] ?? "unspecified"],"\(folder)/manifest.json")
    print("TRAJECTORY WINDOW: \(folder), \(frames.count) frames, \(times.first!)...\(times.last!)")
}

private struct OracleQuery { var x: UInt32; var y: UInt32 }
private let oracleMSL = """
kernel void trajectoryOracle(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],device const uint2 *points [[buffer(0)]],device float *costs [[buffer(1)]],constant uint2 &geometry [[buffer(2)]],uint2 p [[thread_position_in_grid]]) {
    uint span=geometry.x*2+1;
    if(p.x>=span*span || p.y>=geometry.y) return;
    float2 v=float2(int(p.x%span)-int(geometry.x),int(p.x/span)-int(geometry.x));
    float2 center=float2(points[p.y]);
    if(any(center+v-4<0)||center.x+v.x+3>=a.get_width()||center.y+v.y+3>=a.get_height()) { costs[p.y*span*span+p.x]=INFINITY; return; }
    costs[p.y*span*span+p.x]=densePatchCost(a,b,center,v);
}
"""

// Exhaustive integer search over the SAME exposure-normalized, blurred pyramid as production.
// This is a photometric reference, never semantic ground truth for occluded/flat/nonrigid patches.
private final class TrajectoryOracle {
    let device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary
    init() throws {
        device=MTLCreateSystemDefaultDevice()!; queue=device.makeCommandQueue()!
        library=try device.makeLibrary(source: denseMotionMSL+oracleMSL,options: nil)
    }
    func references(_ a: Data,_ b: Data,_ w: Int,_ h: Int,_ points: [(Int,Int)],radius: Int) throws -> [[String:Any]] {
        func texture(_ format: MTLPixelFormat,_ width: Int,_ height: Int) -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: width,height: height,mipmapped: false)
            d.storageMode = .shared; d.usage=[.shaderRead,.shaderWrite]; return device.makeTexture(descriptor: d)!
        }
        let command=queue.makeCommandBuffer()!
        func encode(_ name: String,_ textures: [MTLTexture],offset: Float=0) throws {
            let e=command.makeComputeCommandEncoder()!
            e.setComputePipelineState(try device.makeComputePipelineState(function: library.makeFunction(name: name)!))
            for (i,t) in textures.enumerated() { e.setTexture(t,index: i) }
            var value=offset;e.setBytes(&value,length: 4,index: 0)
            let t=textures.last!;e.dispatchThreads(MTLSize(width: t.width,height: t.height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1));e.endEncoding()
        }
        // Match DenseMotionPrototype illuminationOffset exactly.
        var sum=0.0,squares=0.0,n=0
        a.withUnsafeBytes { aa in b.withUnsafeBytes { bb in
            for y in stride(from: 0,to: h,by: 8) { for x in stride(from: 0,to: w,by: 8) {
                var delta=0.0,count=0
                for yy in y..<min(y+8,h) { for xx in x..<min(x+8,w) {
                    let k=(yy*w+xx)*2;delta+=Double(bb.loadUnaligned(fromByteOffset: k,as: UInt16.self))-Double(aa.loadUnaligned(fromByteOffset: k,as: UInt16.self));count+=1
                } }
                delta/=Double(count);sum+=delta;squares+=delta*delta;n+=1
            } }
        } }
        let mean=sum/Double(n),variance=max(0,squares/Double(n)-mean*mean)
        let exposure: Float=mean*mean>variance ? Float(mean/1023) : 0
        var pyramid=[[MTLTexture]]()
        for (i,data) in [a,b].enumerated() {
            let raw=texture(.r16Uint,w,h),original=texture(.r32Float,w,h),blur=texture(.r32Float,w,h)
            data.withUnsafeBytes { raw.replace(region: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: w*2) }
            try encode("denseUpload",[raw,original]);try encode("denseAnalysisBlur",[original,blur],offset: i==0 ? 0 : exposure)
            var levels=[blur]
            for _ in 1..<4 { let t=texture(.r32Float,(levels.last!.width+1)/2,(levels.last!.height+1)/2);try encode("denseDown",[levels.last!,t]);levels.append(t) }
            pyramid.append(levels)
        }
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw NSError(domain: "OraclePyramid",code: 1) }
        var rows=[[String:Any]]()
        let pipeline=try device.makeComputePipelineState(function: library.makeFunction(name: "trajectoryOracle")!)
        for level in 0..<4 {
            let scale=1<<level,r=max(2,radius/scale),span=2*r+1,count=span*span
            let queries=points.map { OracleQuery(x: UInt32(($0.0/scale+2)/4*4),y: UInt32(($0.1/scale+2)/4*4)) }
            let q=queries.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared)! }
            let costs=device.makeBuffer(length: count*points.count*4,options: .storageModeShared)!
            let c=queue.makeCommandBuffer()!,e=c.makeComputeCommandEncoder()!
            e.setComputePipelineState(pipeline);e.setTexture(pyramid[0][level],index: 0);e.setTexture(pyramid[1][level],index: 1)
            e.setBuffer(q,offset: 0,index: 0);e.setBuffer(costs,offset: 0,index: 1)
            var geometry=SIMD2<UInt32>(UInt32(r),UInt32(points.count));e.setBytes(&geometry,length: 8,index: 2)
            e.dispatchThreads(MTLSize(width: count,height: points.count,depth: 1),threadsPerThreadgroup: MTLSize(width: 64,height: 1,depth: 1));e.endEncoding();c.commit();c.waitUntilCompleted()
            guard c.status == .completed else { throw NSError(domain: "OracleSearch",code: 1) }
            let values=costs.contents().assumingMemoryBound(to: Float.self)
            for i in points.indices {
                var best=Float.infinity,index=0
                for j in 0..<count where values[i*count+j]<best { best=values[i*count+j];index=j }
                let dx=index%span-r,dy=index/span-r
                var second=Float.infinity
                for j in 0..<count where abs(j%span-r-dx)>2 || abs(j/span-r-dy)>2 { second=min(second,values[i*count+j]) }
                let gap=(second-best)/max(second,1e-10)
                let boundary=abs(dx)==r || abs(dy)==r
                rows.append(["point":i,"level":level,"x":queries[i].x,"y":queries[i].y,"dx":dx,"dy":dy,"cost":best.isFinite ? best : -1,"distinctSecondCost":second.isFinite ? second : -1,"gap":gap.isFinite ? gap : 0,"boundary":boundary,"eligible":best.isFinite && gap>0.1 && !boundary,"radius":r])
            }
        }
        return rows
    }
}

func replayTrajectoryDiagnostic(folder: String) throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RIFT_DENSE_CANDIDATES"] == "1" else { throw NSError(domain: "Set RIFT_DENSE_CANDIDATES=1 for replay",code: 1) }
    let manifest=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/manifest.json"))) as! [String:Any]
    let w=manifest["width"] as! Int,h=manifest["height"] as! Int,times=manifest["sourcePTS"] as! [Double]
    let pair=Int(env["MV_TRAJECTORY_PAIR"] ?? "4")!,radius=Int(env["MV_TRAJECTORY_RADIUS"] ?? "256")!
    precondition(pair>0 && pair+2<times.count && (4...384).contains(radius))
    let rois=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/regions.json"))) as! [[String:Any]]
    var points=[(Int,Int)](),labels=[String]()
    for roi in rois {
        let rect=roi["rect"] as! [Int],step=roi["step"] as? Int ?? 16
        precondition(rect.count==4 && step>=4 && rect[0]>=4 && rect[1]>=4 && rect[0]+rect[2]<w-4 && rect[1]+rect[3]<h-4)
        for y in stride(from: rect[1],to: rect[1]+rect[3],by: step) { for x in stride(from: rect[0],to: rect[0]+rect[2],by: step) { points.append((x/4*4,y/4*4));labels.append(roi["name"] as! String) } }
    }
    precondition(!points.isEmpty && points.count<=256)
    func frame(_ i: Int) throws -> Data {
        let data=try Data(contentsOf: URL(fileURLWithPath: "\(folder)/source_\(i).u16"))
        precondition(data.count==w*h*2)
        let expected=(manifest["sha256"] as! [String])[i]
        precondition(SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()==expected,"Fixture checksum mismatch")
        return data
    }
    let first=try frame(pair),last=try frame(pair+1)
    let context=try DenseMotionPrototype.TemporalContext(before: frame(pair-1),after: frame(pair+2),beforeInterval: Float((times[pair]-times[pair-1])/(times[pair+1]-times[pair])),afterInterval: Float((times[pair+2]-times[pair+1])/(times[pair+1]-times[pair])))
    let oracle=try TrajectoryOracle(),refs=try oracle.references(first,last,w,h,points,radius: radius)
    let output="\(folder)/pair_\(pair)"+(radius==256 ? "" : "_radius\(radius)");try FileManager.default.createDirectory(atPath: output,withIntermediateDirectories: true)
    try trajectoryJSON(refs,output+"/oracle.json")
    let levels=(0..<4).map { l in LevelSpec(width: w>>l,height: h>>l,blockSize: l==0 ? 8 : 16,searchHalfPel: l==0 ? 8 : (l==1 ? 16 : 32),halfPelRefine: l==0,inheritFactor: l==0 ? 4 : (l==3 ? 1 : 2)) }
    let search=try MotionSearchEngine(msl: motionShadersMSL,spec: levels,lambdaPx: 1,smoothL0: true,gateL0: true,temporalGatePx: 0)
    _=search.runPair(cur: first,ref: last);let forward=search.downloadMV(level: 0)
    _=search.runPair(cur: last,ref: first);let backward=search.downloadMV(level: 0)
    let dense=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    let baseline=try dense.interpolate(first: first,last: last,forward: forward,backward: backward,time: 0.5,context: context)
    var stages=[[String:Any]]()
    func collect(_ name: String,_ width: Int,_ height: Int,_ records: [SIMD4<Float>],_ candidates: Bool) {
        // Forward direction only; reverse trajectory is a separate source-coordinate query.
        guard name.hasPrefix("d0/") || name=="d1/assessment/denseTVAssess" || name.hasPrefix("synthesis/") else { return }
        let components=name.split(separator: "/"),level=components.count>1 ? Int(components[1].dropFirst()) ?? 0 : 0
        var samples=[[String:Any]]()
        for (i,point) in points.enumerated() {
            let patch=name.contains("densePatch") && !name.contains("Aggregate")
            let reference=refs.first { $0["point"] as? Int==i && $0["level"] as? Int==level }!
            let anchorX=Int(reference["x"] as! UInt32),anchorY=Int(reference["y"] as! UInt32)
            var x=patch ? anchorX/4 : anchorX,y=patch ? anchorY/4 : anchorY
            if name.hasPrefix("synthesis/") {
                x=Int((Float(point.0)+0.5*Float(reference["dx"] as! Int)).rounded())
                y=Int((Float(point.1)+0.5*Float(reference["dy"] as! Int)).rounded())
            }
            if name.contains("aggregateCandidates") { x=anchorX/4;y=anchorY/4 }
            if name.hasPrefix("d1/") {
                x=anchorX+(reference["dx"] as! Int);y=anchorY+(reference["dy"] as! Int)
            }
            guard x>=0 && y>=0 && x<width && y<height else { continue }
            let aggregate=name.contains("aggregateCandidates")
            let stride=candidates ? 16 : (aggregate ? 4 : 1)
            let vectors=(0..<stride).compactMap { j -> [Float]? in
                let index=aggregate ? min(height-1,y+j/2)*width+min(width-1,x+j%2) : (y*width+x)*(candidates ? 16 : 1)+j
                let v=records[index]
                if candidates && v.w==0 { return nil }
                return [v.x,v.y,v.z,v.w]
            }
            samples.append(["point":i,"region":labels[i],"vectors":vectors])
        }
        stages.append(["stage":name,"level":level,"candidates":candidates || name.contains("aggregateCandidates"),"samples":samples])
    }
    dense.diagnosticObserver={ collect($0,$1,$2,$3,false) }
    dense.candidateObserver={ collect($0,$1,$2,$3,true) }
    let traced=try dense.interpolate(first: first,last: last,forward: forward,backward: backward,time: 0.5,context: context)
    precondition(traced.pixels==baseline.pixels && traced.forward==baseline.forward && traced.backward==baseline.backward && traced.reliability==baseline.reliability && traced.mappingResidual==baseline.mappingResidual,"Instrumentation changed output")
    try trajectoryJSON(stages,output+"/stages.json")
    try trajectoryPNG(first,w,h,output+"/original0.png");try trajectoryPNG(last,w,h,output+"/original1.png")
    try trajectoryPNG(traced.pixels.withUnsafeBytes { Data($0) },w,h,output+"/midpoint.png")
    try trajectoryJSON(["pair":pair,"PTS":[times[pair],times[pair+1]],"points":points.map { [$0.0,$0.1] },"regions":labels,"radius":radius,"traceByteIdentical":true,"scope":"forward proposals and winners; photometric reference, not semantic truth; intrusive timings excluded"],output+"/run.json")
    print("TRAJECTORY TRACE: \(output), \(points.count) blocks; byte-identical outputs")
}

func checkTrajectoryDiagnostic() throws {
    let w=96,h=64
    let a=(0..<w*h).map { i -> UInt16 in
        var v=UInt32(i)&*1664525&+1013904223;v ^= v>>13;v=v&*2246822519;return UInt16(v%800+100)
    }
    let b=(0..<w*h).map { i in a[(i/w)*w+max(0,i%w-8)] }
    func data(_ v: [UInt16]) -> Data { v.withUnsafeBytes { Data($0) } }
    let oracle=try TrajectoryOracle()
    let reference=try oracle.references(data(a),data(b),w,h,[(40,32)],radius: 16)
    precondition(reference[0]["dx"] as! Int==8 && reference[0]["dy"] as! Int==0 && reference[0]["eligible"] as! Bool,"Exhaustive translation oracle failed")
    let flat=data(Array(repeating: UInt16(500),count: w*h))
    let ambiguous=try oracle.references(flat,flat,w,h,[(40,32)],radius: 16)
    precondition(!(ambiguous[0]["eligible"] as! Bool),"Flat texture must not count as known motion")
    let dense=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    let count=(w/8)*(h/8),f=Array(repeating: SIMD2<Int32>(16,0),count: count),r=Array(repeating: SIMD2<Int32>(-16,0),count: count)
    let baseline=try dense.interpolate(first: data(a),last: data(b),forward: f,backward: r,time: 0.5)
    var candidates=0,observations=0
    dense.candidateObserver={ _,width,height,records in
        precondition(records.count==width*height*16)
        candidates+=records.filter { $0.w != 0 }.count
    }
    dense.diagnosticObserver={ _,width,height,records in precondition(records.count==width*height);observations+=1 }
    let result=try dense.interpolate(first: data(a),last: data(b),forward: f,backward: r,time: 0.5)
    precondition(result.pixels==baseline.pixels && result.forward==baseline.forward && result.backward==baseline.backward && result.reliability==baseline.reliability && result.mappingResidual==baseline.mappingResidual)
    precondition(observations>0)
    if ProcessInfo.processInfo.environment["RIFT_DENSE_CANDIDATES"] == "1" { precondition(candidates>0) }
    let hash=SHA256.hash(data: data(result.pixels)).map { String(format: "%02x",$0) }.joined()
    print("TRAJECTORY CHECK: known +8px, ambiguous flat rejection, trace identity, candidates=\(candidates), sha256=\(hash)")
}
