import Foundation
import Interpolation

// Probe-only local ownership: choose a motion hypothesis rather than blending
// foreground/background velocities. Production shader remains unchanged.
let contourWarpShadersMSL: String = {
    let helper = """
    float2 contourMotion(texture2d<uint, access::read> a, texture2d<uint, access::read> b,
                         device const int2 *mv, float2 p, uint gw, uint gh, uint bs, float t) {
        float2 g=clamp((p+0.5f)/float(bs)-0.5f,float2(0),float2(gw-1,gh-1));
        int2 lo=int2(floor(g)), hi=min(lo+1,int2(gw-1,gh-1));
        int2 cells[4]={lo,int2(hi.x,lo.y),int2(lo.x,hi.y),hi};
        // Nearest block wins a tie, preserving spatial continuity in flat areas.
        int2 nearest=int2(round(g));
        float2 best=float2(mv[nearest.y*gw+nearest.x])*0.5f;
        float bestCost=INFINITY;
        for (int candidate=-1;candidate<4;++candidate) {
            float2 v=candidate<0 ? best : float2(mv[cells[candidate].y*gw+cells[candidate].x])*0.5f;
            float cost=0;
            for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
                float2 q=p+float2(x,y);
                float a0=sampleBilinearU16(a,q-t*v,a.get_width(),a.get_height()).x;
                float b1=sampleBilinearU16(b,q+(1-t)*v,b.get_width(),b.get_height()).x;
                cost+=abs(a0-b1);
            }
            if (cost<bestCost) { bestCost=cost; best=v; }
        }
        return best;
    }

    """
    let entry = "kernel void warpBlend("
    precondition(warpShadersMSL.contains(entry))
    var result = warpShadersMSL.replacingOccurrences(of: entry, with: helper+entry)
    let original = "float2 flow = sampleMVBilinear(mv, float2(float(gid.x), float(gid.y)), u.gridW, u.gridH, bs);"
    precondition(result.contains(original))
    result = result.replacingOccurrences(of: original, with: "float2 flow = contourMotion(tex0,tex1,mv,float2(gid),u.gridW,u.gridH,bs,u.t);")
    return result
}()

let projectedContourWarpShadersMSL: String = {
    let loop = "for (int candidate=-1;candidate<4;++candidate)"
    let fetch = "candidate<0 ? best : float2(mv[cells[candidate].y*gw+cells[candidate].x])*0.5f"
    precondition(contourWarpShadersMSL.contains(loop) && contourWarpShadersMSL.contains(fetch))
    return contourWarpShadersMSL.replacingOccurrences(of: loop,with: "for (int candidate=-1;candidate<7;++candidate)")
        .replacingOccurrences(of: fetch,with: "candidate<0 ? best : (candidate<4 ? float2(mv[cells[candidate].y*gw+cells[candidate].x])*0.5f : float2(mv[(candidate-3)*gw*gh+nearest.y*gw+nearest.x])*0.5f)")
}()

func projectContourCandidates(_ field: [SIMD2<Int32>], gridW: Int, gridH: Int, block: Int, time: Float) -> [SIMD2<Int32>] {
    let count=gridW*gridH
    precondition(field.count==count && block>0 && time>=0 && time<=1)
    var output=field+field+field+field
    var distances=[Float](repeating: .infinity,count: count*3)
    for index in field.indices {
        let vector=field[index]
        let gx=Float(index%gridW)+time*Float(vector.x)/(2*Float(block))
        let gy=Float(index/gridW)+time*Float(vector.y)/(2*Float(block))
        let x0=Int(floor(gx)), y0=Int(floor(gy))
        for y in y0...y0+1 { for x in x0...x0+1 {
            guard x>=0 && x<gridW && y>=0 && y<gridH else { continue }
            let cell=y*gridW+x
            let distance=(Float(x)-gx)*(Float(x)-gx)+(Float(y)-gy)*(Float(y)-gy)
            if (1...3).contains(where: { output[$0*count+cell]==vector && distances[($0-1)*count+cell].isFinite }) { continue }
            var slot=0
            for s in 1..<3 where distances[s*count+cell]>distances[slot*count+cell] { slot=s }
            if distance<distances[slot*count+cell] {
                distances[slot*count+cell]=distance
                output[(slot+1)*count+cell]=vector
            }
        } }
    }
    return output
}

func checkContourOwnership() throws {
    let w=64, h=48
    func scene(_ offset: Int) -> [UInt16] {
        (0..<w*h).map { i in
            let x=i%w, y=i/w
            if x>=20+offset && x<36+offset && y>=16 && y<32 {
                return UInt16(700+((x-offset)*17+y*31)%250)
            }
            return UInt16(64+(x*13+y*19)%150)
        }
    }
    let first=scene(0), last=scene(8), truth=scene(4)
    let field: [SIMD2<Int32>] = (0..<48).map { i in
        let x=(i%8)*8+4, y=(i/8)*8+4
        return x>=24 && x<40 && y>=16 && y<32 ? SIMD2<Int32>(16,0) : .zero
    }
    let baseline=try WarpEngine(msl: warpShadersMSL)
    let candidate=try WarpEngine(msl: contourWarpShadersMSL)
    let a=baseline.interpolate(I0: first,I1: last,mv: field,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: 0.5).0
    let b=candidate.interpolate(I0: first,I1: last,mv: field,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: 0.5).0
    precondition(a.count==truth.count && b.count==truth.count)
    func error(_ image: [UInt16]) -> Double {
        zip(image,truth).reduce(0.0) { $0+Double(abs(Int($1.0)-Int($1.1))) }/Double(truth.count)
    }
    print("CONTOUR CHECK: layered synthetic MAE baseline=\(error(a)), candidate=\(error(b))")
    precondition(error(b)<error(a), "Motion ownership did not improve known layered motion")
    for time: Float in [0,1] {
        let endpoint=candidate.interpolate(I0: first,I1: last,mv: field,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: time).0
        precondition(endpoint == (time==0 ? first : last), "Contour experiment changed endpoint")
    }
    let still=candidate.interpolate(I0: first,I1: first,mv: field,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: 0.5).0
    precondition(still==first, "Contour experiment changed static content")
    let sourceField: [SIMD2<Int32>] = (0..<48).map { i in
        let x=(i%8)*8+4, y=(i/8)*8+4
        return x>=20 && x<36 && y>=16 && y<32 ? SIMD2<Int32>(16,0) : .zero
    }
    let pool=projectContourCandidates(sourceField,gridW: 8,gridH: 6,block: 8,time: 0.5)
    precondition(Array(pool.prefix(sourceField.count))==sourceField)
    let projected=try WarpEngine(msl: projectedContourWarpShadersMSL)
    let projectedOutput=projected.interpolate(I0: first,I1: last,mv: pool,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: 0.5).0
    let sourceBaseline=baseline.interpolate(I0: first,I1: last,mv: sourceField,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: 0.5).0
    precondition(projectedOutput.count==truth.count)
    print("CONTOUR PROJECT: source-field MAE baseline=\(error(sourceBaseline)), projected=\(error(projectedOutput))")
    precondition(error(projectedOutput)<error(sourceBaseline))
    for time: Float in [0,1] {
        let endpoint=projected.interpolate(I0: first,I1: last,mv: pool,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: time).0
        precondition(endpoint == (time==0 ? first : last))
    }
    let projectedStill=projected.interpolate(I0: first,I1: first,mv: pool,width: w,height: h,gridW: 8,gridH: 6,blockSize: 8,t: 0.5).0
    precondition(projectedStill==first)
    let constant=[SIMD2<Int32>](repeating: SIMD2<Int32>(16,0),count: 48)
    precondition(projectContourCandidates(constant,gridW: 8,gridH: 6,block: 8,time: 0.5).allSatisfy { $0==constant[0] })
}
