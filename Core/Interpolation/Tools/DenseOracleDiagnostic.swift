import Foundation
import Metal
import Interpolation
import CryptoKit
import CoreGraphics
import ImageIO

// Offline full-coverage 8x8 lattice. Each workgroup exhausts every integer displacement;
// only the winning vector/cost survives, so memory does not grow with search radius.
private let fullOracleMSL = """
float fullCost(texture2d<float,access::read> a,texture2d<float,access::read> b,int2 p,int2 v) {
    if(any(p+v-4<0)||any(p+v+3>=int2(b.get_width(),b.get_height()))) return INFINITY;
    float c=0;
    for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
        float d=a.read(uint2(p+int2(x,y))).r-b.read(uint2(p+v+int2(x,y))).r;c+=d*d;
    }
    return c/64;
}
bool fullBetter(float c,uint label,float best,uint winner,uint radius,uint span) {
    int2 a=int2(label%span,label/span)-int(radius),b=int2(winner%span,winner/span)-int(radius);
    int aa=a.x*a.x+a.y*a.y,bb=b.x*b.x+b.y*b.y;
    return c<best || (c==best && (aa<bb || (aa==bb && label<winner)));
}
kernel void fullOracle(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> b [[texture(1)]],device float4 *out [[buffer(0)]],constant uint4 &u [[buffer(1)]],uint block [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    uint index=block+u.w,span=2*u.z+1;
    int2 p=min(int2(index%u.x,index/u.x)*8+4,int2(a.get_width(),a.get_height())-4);
    float best=INFINITY;uint winner=0;
    for(uint j=tid;j<span*span;j+=256) {
        int2 v=int2(j%span,j/span)-int(u.z);float c=fullCost(a,b,p,v);
        if(fullBetter(c,j,best,winner,u.z,span)) {best=c;winner=j;}
    }
    threadgroup float cost[256];threadgroup uint label[256];cost[tid]=best;label[tid]=winner;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint stride=128;stride>0;stride/=2) {
        if(tid<stride && fullBetter(cost[tid+stride],label[tid+stride],cost[tid],label[tid],u.z,span)) {cost[tid]=cost[tid+stride];label[tid]=label[tid+stride];}
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if(tid==0) out[index]=float4(float2(int2(label[0]%span,label[0]/span)-int(u.z)),cost[0],0);
}
// One synchronous pass; never average vectors across a boundary. Allow <=1% unary
// degradation and penalize disagreement up to one pixel with photometrically similar neighbors.
kernel void fullRegularize(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> b [[texture(1)]],device const float4 *input [[buffer(0)]],device float4 *out [[buffer(1)]],constant uint2 &size [[buffer(2)]],uint2 g [[thread_position_in_grid]]) {
    if(any(g>=size)) return;
    uint k=g.y*size.x+g.x;int2 p=min(int2(g)*8+4,int2(a.get_width(),a.get_height())-4);
    int2 offsets[4]={int2(-1,0),int2(1,0),int2(0,-1),int2(0,1)};
    float2 candidates[5];candidates[0]=input[k].xy;float weights[4];float2 neighbors[4];
    for(uint j=0;j<4;++j) {
        int2 q=clamp(int2(g)+offsets[j],int2(0),int2(size)-1);neighbors[j]=input[q.y*size.x+q.x].xy;candidates[j+1]=neighbors[j];
        int2 center=min(q*8+4,int2(a.get_width(),a.get_height())-4);float difference=0;
        for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) difference+=abs(a.read(uint2(p+int2(x,y))).r-a.read(uint2(center+int2(x,y))).r)/64;
        weights[j]=difference<0.01f ? 1-difference/0.01f : 0;
    }
    float best=INFINITY;float4 chosen=input[k];
    for(uint j=0;j<5;++j) {
        float c=fullCost(a,b,p,int2(candidates[j]));if(c>input[k].z*1.01f+1e-10f) continue;
        float penalty=0;for(uint n=0;n<4;++n) penalty+=weights[n]*min(length(candidates[j]-neighbors[n]),1.0f);
        float score=c+1e-7f*penalty;if(score<best) {best=score;chosen=float4(candidates[j],c,0);}
    }
    out[k]=chosen;
}
"""

private final class FullOracle {
    let device=MTLCreateSystemDefaultDevice()!,queue: MTLCommandQueue,library: MTLLibrary
    init() throws {queue=device.makeCommandQueue()!;library=try device.makeLibrary(source: denseMotionMSL+fullOracleMSL,options: nil)}
    func fields(_ a: Data,_ b: Data,_ w: Int,_ h: Int,_ radius: Int) throws -> [[SIMD4<Float>]] {
        precondition(w%8==0 && h%8==0 && a.count==w*h*2 && b.count==a.count)
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: w,height: h,mipmapped: false);d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite];return device.makeTexture(descriptor: d)!
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {try device.makeComputePipelineState(function: library.makeFunction(name: name)!)}
        func finish(_ c: MTLCommandBuffer) throws {c.commit();c.waitUntilCompleted();guard c.status == .completed else {throw c.error ?? NSError(domain: "FullOracleGPU",code: 1)}}
        var sum=0.0,squares=0.0,n=0
        a.withUnsafeBytes {aa in b.withUnsafeBytes {bb in
            for y in stride(from: 0,to: h,by: 8) {for x in stride(from: 0,to: w,by: 8) {
                var d=0.0
                for yy in y..<y+8 {for xx in x..<x+8 {let k=(yy*w+xx)*2;d+=Double(bb.loadUnaligned(fromByteOffset: k,as: UInt16.self))-Double(aa.loadUnaligned(fromByteOffset: k,as: UInt16.self))}}
                d/=64;sum+=d;squares+=d*d;n+=1
            }}
        }}
        let mean=sum/Double(n),variance=max(0,squares/Double(n)-mean*mean),offset: Float=mean*mean>variance ? Float(mean/1023) : 0
        var images=[MTLTexture]()
        let command=queue.makeCommandBuffer()!
        for (i,data) in [a,b].enumerated() {
            let raw=texture(.r16Uint),original=texture(.r32Float),blur=texture(.r32Float)
            data.withUnsafeBytes {raw.replace(region: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: w*2)}
            for (name,input,output) in [("denseUpload",raw,original),("denseAnalysisBlur",original,blur)] {
                let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(try pipeline(name));e.setTexture(input,index: 0);e.setTexture(output,index: 1);var value=i==0 ? Float(0) : offset;e.setBytes(&value,length: 4,index: 0);e.dispatchThreads(MTLSize(width: w,height: h,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1));e.endEncoding()
            }
            images.append(blur)
        }
        try finish(command)
        let count=w*h/64,search=try pipeline("fullOracle"),regularize=try pipeline("fullRegularize")
        var results=[[SIMD4<Float>]]()
        for direction in 0..<2 {
            let raw=device.makeBuffer(length: count*16,options: .storageModeShared)!,smooth=device.makeBuffer(length: count*16,options: .storageModeShared)!
            // Small command buffers avoid GPU watchdog timeouts and bound each work submission.
            for start in stride(from: 0,to: count,by: 64) {
                let c=queue.makeCommandBuffer()!,e=c.makeComputeCommandEncoder()!;e.setComputePipelineState(search);e.setTexture(images[direction],index: 0);e.setTexture(images[1-direction],index: 1);e.setBuffer(raw,offset: 0,index: 0)
                var u=SIMD4<UInt32>(UInt32(w/8),UInt32(h/8),UInt32(radius),UInt32(start));e.setBytes(&u,length: 16,index: 1);e.dispatchThreadgroups(MTLSize(width: min(64,count-start),height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 256,height: 1,depth: 1));e.endEncoding();try finish(c)
            }
            let c=queue.makeCommandBuffer()!,e=c.makeComputeCommandEncoder()!;e.setComputePipelineState(regularize);e.setTexture(images[direction],index: 0);e.setTexture(images[1-direction],index: 1);e.setBuffer(raw,offset: 0,index: 0);e.setBuffer(smooth,offset: 0,index: 1);var size=SIMD2<UInt32>(UInt32(w/8),UInt32(h/8));e.setBytes(&size,length: 8,index: 2);e.dispatchThreads(MTLSize(width: w/8,height: h/8,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1));e.endEncoding();try finish(c)
            let values=Array(UnsafeBufferPointer(start: smooth.contents().assumingMemoryBound(to: SIMD4<Float>.self),count: count))
            precondition(values.allSatisfy {$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
            results.append(values)
        }
        return results
    }
}

private func fullJSON(_ value: Any,_ path: String) throws {try JSONSerialization.data(withJSONObject: value,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))}
private func fullPNG(_ values: [UInt16],_ w: Int,_ h: Int,_ path: String) throws {
    let pixels=Data(values.map {UInt8(clamping: Int($0)/4)}),provider=CGDataProvider(data: pixels as CFData)!
    let image=CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: w,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    let dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest))
}

func checkFullOracle() throws {
    let w=64,h=48
    let a=(0..<w*h).map {i -> UInt16 in var v=UInt32(i)&*1664525&+1013904223;v ^= v>>13;return UInt16(v%800+100)}
    let b=(0..<w*h).map {a[($0/w)*w+max(0,$0%w-8)]}
    let fields=try FullOracle().fields(a.withUnsafeBytes {Data($0)},b.withUnsafeBytes {Data($0)},w,h,16)
    for y in 1..<h/8-1 {for x in 2..<w/8-2 {precondition(fields[0][y*(w/8)+x].x==8 && fields[0][y*(w/8)+x].y==0)}}
    let flat=Array(repeating: UInt16(500),count: w*h).withUnsafeBytes {Data($0)}
    let still=try FullOracle().fields(flat,flat,w,h,16)
    precondition(still.flatMap {$0}.allSatisfy {$0.x==0 && $0.y==0},"Flat ties must prefer zero motion")
    let split=(0..<w*h).map {i in let x=i%w;return a[(i/w)*w+(x<w/2 ? max(0,x-8) : min(w-1,x+8))]}
    let splitFields=try FullOracle().fields(a.withUnsafeBytes {Data($0)},split.withUnsafeBytes {Data($0)},w,h,16)
    for y in 1..<h/8-1 {
        precondition(splitFields[0][y*(w/8)+1].x==8 && splitFields[0][y*(w/8)+6].x == -8,"Regularization crossed motion discontinuity")
    }
    print("FULL ORACLE CHECK: exact +8 translation, flat ties zero, opposite-motion boundary preserved, finite full coverage")
}

func replayFullOracle(folder: String) throws {
    let env=ProcessInfo.processInfo.environment,target=env["MV_FULL_ORACLE_OUTPUT"]!
    let manifest=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/manifest.json"))) as! [String:Any]
    let w=manifest["width"] as! Int,h=manifest["height"] as! Int,pts=manifest["sourcePTS"] as! [Double],hashes=manifest["sha256"] as! [String]
    let radius=Int(env["MV_FULL_ORACLE_RADIUS"] ?? "256")!,start=Int(env["MV_FULL_ORACLE_START"] ?? "0")!,end=Int(env["MV_FULL_ORACLE_END"] ?? String(pts.count-2))!
    precondition((4...384).contains(radius) && start>=0 && end<pts.count-1 && start<=end)
    try FileManager.default.createDirectory(atPath: target,withIntermediateDirectories: true)
    func frame(_ i: Int) throws -> Data {
        let data=try Data(contentsOf: URL(fileURLWithPath: "\(folder)/source_\(i).u16"));precondition(data.count==w*h*2 && SHA256.hash(data: data).map {String(format: "%02x",$0)}.joined()==hashes[i]);return data
    }
    let oracle=try FullOracle()
    let levels=(0..<4).map {l in LevelSpec(width: w>>l,height: h>>l,blockSize: l==0 ? 8 : 16,searchHalfPel: l==0 ? 8 : (l==1 ? 16 : 32),halfPelRefine: l==0,inheritFactor: l==0 ? 4 : (l==3 ? 1 : 2))}
    let search=try MotionSearchEngine(msl: motionShadersMSL,spec: levels,lambdaPx: 1,smoothL0: true,gateL0: true,temporalGatePx: 0)
    let dense=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    // Construct a separate instance with the oracle flag off to exercise the actual opt-in gate.
    let saved=env["RIFT_DENSE_ORACLE"];setenv("RIFT_DENSE_ORACLE","0",1)
    let disabled=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    if let saved=saved {setenv("RIFT_DENSE_ORACLE",saved,1)} else {unsetenv("RIFT_DENSE_ORACLE")}
    for pair in start...end {
        let output="\(target)/pair_\(pair)";try FileManager.default.createDirectory(atPath: output,withIntermediateDirectories: true)
        let a=try frame(pair),b=try frame(pair+1),began=Date()
        let cacheInfo: [String:Any]=["radius":radius,"sourceSHA256":[hashes[pair],hashes[pair+1]],"algorithm":"full-8x8-ssd-edge-regularized-v1"]
        let cacheData=try JSONSerialization.data(withJSONObject: cacheInfo,options: [.sortedKeys])
        let cacheURL=URL(fileURLWithPath: output+"/cache.json")
        if FileManager.default.fileExists(atPath: cacheURL.path) {let existing=try Data(contentsOf: cacheURL);precondition(existing==cacheData,"Oracle cache configuration mismatch")}
        else {precondition(!FileManager.default.fileExists(atPath: output+"/reference-0.f32"),"Remove unversioned oracle cache before replay");try cacheData.write(to: cacheURL)}

        var grids=[[SIMD4<Float>]]()
        for direction in 0..<2 {
            let path="\(output)/reference-\(direction).f32"
            if FileManager.default.fileExists(atPath: path) {let data=try Data(contentsOf: URL(fileURLWithPath: path));precondition(data.count==w*h/64*16);grids.append(data.withUnsafeBytes {Array($0.bindMemory(to: SIMD4<Float>.self))})}
        }
        if grids.count != 2 {
            grids=try oracle.fields(a,b,w,h,radius)
            for direction in 0..<2 {try grids[direction].withUnsafeBytes {Data($0)}.write(to: URL(fileURLWithPath: "\(output)/reference-\(direction).f32"))}
        }
        precondition(grids.flatMap {$0}.allSatisfy {$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs($0.x)<=Float(radius) && abs($0.y)<=Float(radius) && $0.z>=0},"Invalid cached reference grid")
        _=search.runPair(cur: a,ref: b);let f=search.downloadMV(level: 0)
        _=search.runPair(cur: b,ref: a);let r=search.downloadMV(level: 0)
        let context: DenseMotionPrototype.TemporalContext? = pair>0 && pair+2<pts.count ? try .init(before: frame(pair-1),after: frame(pair+2),beforeInterval: Float((pts[pair]-pts[pair-1])/(pts[pair+1]-pts[pair])),afterInterval: Float((pts[pair+2]-pts[pair+1])/(pts[pair+1]-pts[pair]))) : nil
        func replace(_ f: [SIMD4<Float>],_ r: [SIMD4<Float>]) -> ([SIMD4<Float>],[SIMD4<Float>]) {
            var fields=[f,r]
            for d in 0..<2 {for y in 0..<h {for x in 0..<w {let v=grids[d][(y/8)*(w/8)+x/8];fields[d][y*w+x].x=v.x;fields[d][y*w+x].y=v.y}}}
            return (fields[0],fields[1])
        }
        let times: [Float]=[0.25,0.5,0.75]
        dense.diagnosticFlowOverride=nil
        let current=try dense.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
        dense.diagnosticFlowOverride=replace;disabled.diagnosticFlowOverride=replace
        let reference=try dense.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
        let off=try disabled.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
        if pair==4 {
            let refs=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/pair_4/oracle.json"))) as! [[String:Any]]
            var masks=Array(repeating: Array(repeating: false,count: w*h),count: 2)
            for ref in refs where ref["level"] as! Int==0 && ref["eligible"] as! Bool {
                let x=ref["x"] as! Int,y=ref["y"] as! Int,dx=ref["dx"] as! Int,dy=ref["dy"] as! Int
                for yy in y-4..<y+4 {for xx in x-4..<x+4 {
                    if xx>=0 && xx<w && yy>=0 && yy<h {masks[0][yy*w+xx]=true}
                    if xx+dx>=0 && xx+dx<w && yy+dy>=0 && yy+dy<h {masks[1][(yy+dy)*w+xx+dx]=true}
                }}
            }
            dense.diagnosticFlowOverride={f,r in
                let complete=replace(f,r);var fields=[f,r];let all=[complete.0,complete.1]
                for d in 0..<2 {for k in 0..<w*h where masks[d][k] {fields[d][k]=all[d][k]}}
                return (fields[0],fields[1])
            }
            let masked=try dense.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
            for i in times.indices {try fullPNG(masked[i].pixels,w,h,"\(output)/masked_t\(times[i]).png")}
            try fullPNG(masks[0].map {$0 ? UInt16(1023) : 0},w,h,output+"/sparse-mask.png")
            for fill in [false,true] {
                dense.diagnosticFlowOverride={f,r in
                    let complete=replace(f,r);var fields=fill ? [complete.0,complete.1] : [f,r]
                    // Hold A's exact xy substitutions fixed; only fill previously untouched gaps.
                    for ref in refs where ref["level"] as! Int==0 && ref["eligible"] as! Bool {
                        let x=ref["x"] as! Int,y=ref["y"] as! Int,dx=ref["dx"] as! Int,dy=ref["dy"] as! Int
                        for yy in y-4..<y+4 {for xx in x-4..<x+4 {
                            if xx>=0 && xx<w && yy>=0 && yy<h {fields[0][yy*w+xx].x=Float(dx);fields[0][yy*w+xx].y=Float(dy)}
                            if xx+dx>=0 && xx+dx<w && yy+dy>=0 && yy+dy<h {fields[1][(yy+dy)*w+xx+dx].x=Float(-dx);fields[1][(yy+dy)*w+xx+dx].y=Float(-dy)}
                        }}
                    }
                    return (fields[0],fields[1])
                }
                let legacy=try dense.interpolate(first: a,last: b,forward: f,backward: r,times: times,context: context)
                for i in times.indices {try fullPNG(legacy[i].pixels,w,h,"\(output)/legacy-\(fill ? "filled" : "sparse")_t\(times[i]).png")}
            }

        }

        var samples=[[String:Any]]()
        for i in times.indices {
            precondition(off[i].pixels==current[i].pixels && off[i].forward==current[i].forward && off[i].backward==current[i].backward,"Disabled full oracle changed output")
            try fullPNG(current[i].pixels,w,h,"\(output)/current_t\(times[i]).png");try fullPNG(reference[i].pixels,w,h,"\(output)/dense_t\(times[i]).png")
            samples.append(["t":times[i],"changedPixels":zip(current[i].pixels,reference[i].pixels).filter {$0 != $1}.count,"disabledIdentical":true])
        }
        for (i,data) in [a,b].enumerated() {try fullPNG(data.withUnsafeBytes {Array($0.bindMemory(to: UInt16.self))},w,h,"\(output)/original\(i).png")}
        try fullJSON(["pair":pair,"PTS":[pts[pair],pts[pair+1]],"radius":radius,"grid":[w/8,h/8],"spatialCoverage":w*h,"enabled":env["RIFT_DENSE_ORACLE"]=="1","seconds":Date().timeIntervalSince(began),"samples":samples],output+"/run.json")
        print("FULL ORACLE pair=\(pair) seconds=\(Date().timeIntervalSince(began))");fflush(stdout)
    }
}
