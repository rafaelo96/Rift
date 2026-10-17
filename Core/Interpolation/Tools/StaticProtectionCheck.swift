import Foundation
import Metal
import CryptoKit
import CoreGraphics
import ImageIO
import Interpolation

// Offline exact synthesis harness: UInt16 work luma and final fields, no ME/selection changes.
private final class StaticSynthesisProbe {
    let w: Int,h: Int,device: MTLDevice,queue: MTLCommandQueue
    let project: MTLComputePipelineState,synth: MTLComputePipelineState,uploadPipeline: MTLComputePipelineState
    init(source: String,width: Int,height: Int) throws {
        w=width;h=height;device=MTLCreateSystemDefaultDevice()!;queue=device.makeCommandQueue()!
        // Compile-only instrumentation captures each predicate; never alters the runtime shader.
        var source=source.replacingOccurrences(of: "uint2 gid [[thread_position_in_grid]] TRACE_ARG)",with: "uint2 gid [[thread_position_in_grid]] TRACE_ARG, device float4 *evidence [[buffer(11)]])")
        source=source.replacingOccurrences(of: "// Static protection requires agreement along both transport paths.",with: """
        float b0=denseRead(b,q0).r,a1=denseRead(a,q1).r;
        evidence[4*(gid.y*w+gid.x)]=float4(abs(av-bv+offset)*16-(av+bv),abs(v0-b0+offset)*16-(v0+b0),abs(v1-a1-offset)*16-(v1+a1),abs(av-bv+offset)-2*abs(v0-v1+offset)-1.0f/1023.0f);
        evidence[4*(gid.y*w+gid.x)+1]=float4(length(f.xy),length(r.xy),closure0,closure1);
        evidence[4*(gid.y*w+gid.x)+2]=float4(f.z,r.z,denseMatch(a,b,p,p,offset),denseMatch(a,b,q0,q1,offset));
        // Static protection requires agreement along both transport paths.
        """)
        source=source.replacingOccurrences(of: "coordinates.write(float4(q0-p,q1-p),gid); blend.write(alpha,gid);",with: "evidence[4*(gid.y*w+gid.x)+3]=float4(still ? 1 : 0,weights,owned ? 1 : 0,alpha);\n    coordinates.write(float4(q0-p,q1-p),gid); blend.write(alpha,gid);")
        let lib=try device.makeLibrary(source: source,options: nil)
        uploadPipeline=try device.makeComputePipelineState(function: lib.makeFunction(name: "denseUpload")!)
        project=try device.makeComputePipelineState(function: lib.makeFunction(name: "denseProject")!)
        synth=try device.makeComputePipelineState(function: lib.makeFunction(name: "denseSynthesize")!)
    }
    func render(a: [Float],b: [Float],f: [SIMD4<Float>],r: [SIMD4<Float>],time: Float,nativeTenBit: Bool=false) throws -> (pixels: [UInt16],coordinates: [SIMD4<Float>],evidence: [SIMD4<Float>]) {
        let n=w*h;precondition(a.count==n && b.count==n && f.count==n && r.count==n)
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: w,height: h,mipmapped: false);d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite];return device.makeTexture(descriptor: d)!
        }
        func upload<T>(_ values: [T],_ format: MTLPixelFormat) -> MTLTexture {
            let t=texture(format);values.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: w*MemoryLayout<T>.stride) };return t
        }
        let images=[upload(a,.r32Float),upload(b,.r32Float),upload(f,.rgba32Float),upload(r,.rgba32Float)]
        let out=texture(.r16Uint),confidence=texture(.r32Float),residual=texture(.rg32Float),coords=texture(.rgba32Float),blend=texture(.r32Float)
        let owners=(0..<2).map { _ in device.makeBuffer(length: n*4,options: .storageModeShared)! }
        owners.forEach { memset($0.contents(),0,$0.length) }
        let evidence=device.makeBuffer(length: n*64,options: .storageModeShared)!
        memset(evidence.contents(),0,evidence.length)
        let command=queue.makeCommandBuffer()!;var bits=UInt32(UInt32.bitWidth-UInt32(n).leadingZeroBitCount),offset=Float(0)
        func dispatch(_ e: MTLComputeCommandEncoder) { e.dispatchThreads(MTLSize(width: w,height: h,depth: 1),threadsPerThreadgroup: MTLSize(width: 16,height: 8,depth: 1));e.endEncoding() }
        if nativeTenBit {
            for (i,source) in [a,b].enumerated() {
                let raw=upload(source.map { UInt16(($0*1023).rounded()) },.r16Uint)
                let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(uploadPipeline);e.setTexture(raw,index: 0);e.setTexture(images[i],index: 1);dispatch(e)
            }
        }
        for direction in 0..<2 {
            let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(project)
            for (i,image) in (direction==0 ? images : [images[1],images[0],images[3],images[2]]).enumerated() { e.setTexture(image,index: i) }
            var amount=direction==0 ? time : 1-time
            e.setBuffer(owners[direction],offset: 0,index: 0);e.setBytes(&bits,length: 4,index: 1);e.setBytes(&amount,length: 4,index: 2);e.setBytes(&offset,length: 4,index: 3);dispatch(e)
        }
        let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(synth)
        for (i,t) in (images+[out,confidence,residual,coords,blend]).enumerated() { e.setTexture(t,index: i) }
        var t=time,projection=SIMD2<UInt32>(bits,1)
        e.setBytes(&t,length: 4,index: 0);e.setBytes(&projection,length: 8,index: 1);e.setBuffer(owners[0],offset: 0,index: 2);e.setBuffer(owners[1],offset: 0,index: 3);e.setBytes(&offset,length: 4,index: 4);e.setBuffer(evidence,offset: 0,index: 11);dispatch(e)
        command.commit();command.waitUntilCompleted();guard command.status == .completed else { throw command.error ?? NSError(domain: "StaticProbeGPU",code: 1) }
        var pixels=[UInt16](repeating: 0,count: n),coordinates=[SIMD4<Float>](repeating: .zero,count: n)
        pixels.withUnsafeMutableBytes { out.getBytes($0.baseAddress!,bytesPerRow: w*2,from: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0) }
        coordinates.withUnsafeMutableBytes { coords.getBytes($0.baseAddress!,bytesPerRow: w*16,from: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0) }
        return (pixels,coordinates,Array(UnsafeBufferPointer(start: evidence.contents().assumingMemoryBound(to: SIMD4<Float>.self),count: n*4)))
    }
}
private func staticSave(_ pixels: [UInt16],_ w: Int,_ h: Int,_ path: String) {
    let gray=pixels.map { UInt8(clamping: Int($0)/4) },provider=CGDataProvider(data: Data(pixels.map { UInt8(clamping: Int($0)/4) }) as CFData)!
    precondition(gray.count==w*h)
    let image=CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: w,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))
}

func checkStaticProtection() throws {
    let env=ProcessInfo.processInfo.environment,root=env["MV_STATIC_OUTPUT"]!
    try FileManager.default.createDirectory(atPath: root,withIntermediateDirectories: true)
    let baselineSource=try String(contentsOfFile: env["MV_STATIC_BASELINE"]!,encoding: .utf8)
    let candidate=denseMotionMSL
    let w=96,h=64,n=w*h,d=Float(4)
    let baseline=try StaticSynthesisProbe(source: baselineSource,width: w,height: h),updated=try StaticSynthesisProbe(source: candidate,width: w,height: h)
    func signal(_ x: Float,_ y: Float) -> Float { 0.55+0.012*cos(x*Float.pi/4)+0.004*sin(y*0.37) }
    let a=(0..<n).map { signal(Float($0%w),Float($0/w)) },b=(0..<n).map { signal(Float($0%w)-d,Float($0/w)) }
    let f=Array(repeating: SIMD4<Float>(d,0,1,0),count: n),r=Array(repeating: SIMD4<Float>(-d,0,1,0),count: n)
    var results=[[String:Any]]()
    for (name,probe) in [("before",baseline),("after",updated)] {
        let result=try probe.render(a: a,b: b,f: f,r: r,time: 0.5)
        var mae=0.0,frozen=0,count=0,vectorError=0.0
        for y in 8..<h-8 { for x in 8..<w-8 {
            let k=y*w+x;mae+=abs(Double(result.pixels[k])/1023-Double(signal(Float(x)-d/2,Float(y))))
            if result.evidence[k*4+3].x>0 { frozen+=1 }
            vectorError+=Double(abs(result.coordinates[k].x+d/2));count+=1
        } }
        staticSave(result.pixels,w,h,root+"/synthetic-\(name).png")
        results.append(["variant":name,"mae":mae/Double(count),"frozenPixels":frozen,"interiorPixels":count,"inverseSourceErrorPx":vectorError/Double(count)])
        if name=="before" { precondition(frozen>count/10,"Synthetic did not reproduce static-protection failure") }
        if env["MV_STATIC_EXPECT_FIXED"]=="1" && name=="after" { precondition(frozen==0 && vectorError/Double(count)<0.01,"Known 4px motion still freezes") }
    }
    // Stationary content with true zero fields, wrong but reciprocal fields, and ±1 LSB noise.
    var stationary=[[String:Any]]()
    for movingField in [false,true] { for noise in [Float(0),Float(1.0/1023)] {
        let noisy=a.enumerated().map { $0.element+($0.offset%2==0 ? noise : -noise) }
        let sf=movingField ? f : Array(repeating: SIMD4<Float>(0,0,1,0),count: n),sr=movingField ? r : sf
        let before=try baseline.render(a: a,b: noisy,f: sf,r: sr,time: 0.5),after=try updated.render(a: a,b: noisy,f: sf,r: sr,time: 0.5)
        var bad=0,count=0,delta=0.0
        for y in 8..<h-8 { for x in 8..<w-8 {
            let k=y*w+x;delta+=abs(Double(after.pixels[k])-Double(before.pixels[k]))/1023
            if abs(Int(after.pixels[k])-Int((a[k]*1023).rounded()))>1 { bad+=1 };count+=1
        } }
        let jitter=Double(bad)/Double(count)
        precondition(jitter<0.01,"Stationary content jitter >=1%")
        stationary.append(["wrongMovingField":movingField,"noise":noise,"jitterFractionAbove1LSB":jitter,"beforeAfterMAE":delta/Double(count)])
    } }
    let result: [String:Any]=["chip":MTLCreateSystemDefaultDevice()!.name,"knownDisplacement":4,"motion":results,"stationary":stationary,"jitterDefinition":"fraction of interior pixels differing from stationary source by more than one 10-bit code value","mode":"isolated synthesis; no decode/Strong timing claim"]
    try JSONSerialization.data(withJSONObject: result,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: root+"/synthetic.json"))
    print("STATIC SYNTHETIC: \(results)")
}

func replayStaticProtection() throws {
    let env=ProcessInfo.processInfo.environment,folder=env["MV_STATIC_REAL"]!,out=env["MV_STATIC_OUTPUT"]!
    try FileManager.default.createDirectory(atPath: out,withIntermediateDirectories: true)
    let metadata=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder+"/oracle-injection.json"))) as! [String:Any]
    let w=metadata["width"] as! Int,h=metadata["height"] as! Int
    func luma(_ name: String) throws -> [Float] {
        let data=try Data(contentsOf: URL(fileURLWithPath: folder+"/"+name+".u16"));precondition(data.count==w*h*2)
        return data.withUnsafeBytes { bytes in (0..<w*h).map { Float(bytes.loadUnaligned(fromByteOffset: $0*2,as: UInt16.self))/1023 } }
    }
    func field(_ name: String) throws -> [SIMD4<Float>] {
        let data=try Data(contentsOf: URL(fileURLWithPath: folder+"/"+name+".f32"));precondition(data.count==w*h*16)
        return data.withUnsafeBytes { bytes in (0..<w*h).map { bytes.loadUnaligned(fromByteOffset: $0*16,as: SIMD4<Float>.self) } }
    }
    let a=try luma("source0"),b=try luma("source1"),f=try field("forward"),r=try field("backward")
    let baselineSource=try String(contentsOfFile: env["MV_STATIC_BASELINE"]!,encoding: .utf8)
    var records=[[String:Any]]()
    for (name,source) in [("before",baselineSource),("after",denseMotionMSL)] {
        let probe=try StaticSynthesisProbe(source: source,width: w,height: h)
        for time: Float in [0.25,0.5,0.75] {
            let result=try probe.render(a: a,b: b,f: f,r: r,time: time,nativeTenBit: true)
            staticSave(result.pixels,w,h,out+"/\(name)_t\(time).png")
            if time==0.5 {
                try result.evidence.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: out+"/\(name)-evidence.f32"))
                try result.coordinates.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: out+"/\(name)-coordinates.f32"))
            }
            records.append(["variant":name,"t":time,"staticProtected":stride(from: 3,to: result.evidence.count,by: 4).filter { result.evidence[$0].x>0 }.count,"sha256":SHA256.hash(data: result.pixels.withUnsafeBytes { Data($0) }).map { String(format: "%02x",$0) }.joined()])
        }
    }
    try JSONSerialization.data(withJSONObject: records,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: out+"/real.json"))
    print("STATIC REAL: \(out)")
}
