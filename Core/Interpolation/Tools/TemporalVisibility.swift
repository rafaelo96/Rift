import Foundation

struct VisibilityFields {
    let forward: [SIMD4<Float>]
    let backward: [SIMD4<Float>]
}

// Offline hypothesis only: adjacent endpoint evidence does not certify physical object identity.
struct TemporalVisibility {
    let width: Int, height: Int
    struct Output { var pixels: [UInt16]; var states: [UInt8]; var selected: [UInt8] }
    struct Candidate { let q: SIMD2<Float>, velocity: SIMD2<Float>; let paired: Bool }
    let tolerance: Float = 1.5
    let photometricLimit: Float = 0.02
    func inside(_ p: SIMD2<Float>) -> Bool {p.x>=1 && p.y>=1 && p.x<=Float(width-2) && p.y<=Float(height-2)}
    func length(_ v: SIMD2<Float>) -> Float {sqrt(v.x*v.x+v.y*v.y)}
    func vector(_ v: SIMD4<Float>) -> SIMD2<Float> {SIMD2(v.x,v.y)}
    func sample<T>(_ values: [T], _ p: SIMD2<Float>, _ blend: (T,T,Float)->T) -> T {
        let x=max(0,min(Float(width-1),p.x)),y=max(0,min(Float(height-1),p.y))
        let ix=Int(x),iy=Int(y),jx=min(width-1,ix+1),jy=min(height-1,iy+1)
        return blend(blend(values[iy*width+ix],values[iy*width+jx],x-Float(ix)),blend(values[jy*width+ix],values[jy*width+jx],x-Float(ix)),y-Float(iy))
    }
    func image(_ a: [Float], _ p: SIMD2<Float>) -> Float {sample(a,p) {$0+($1-$0)*$2}}
    func field(_ a: [SIMD4<Float>], _ p: SIMD2<Float>) -> SIMD4<Float> {sample(a,p) {$0+($1-$0)*$2}}
    func cost(_ a: [Float], _ b: [Float], _ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Float {
        var sum:Float=0
        for y in -1...1 {for x in -1...1 {let d=SIMD2<Float>(Float(x),Float(y));sum+=abs(image(a,p+d)-image(b,q+d))}}
        return sum/(9*1023)
    }
    func candidate(isFirst: Bool,p: SIMD2<Float>,t: Float,source: [Float],other: [Float],neighbor: [Float],central: [SIMD4<Float>],opposite: [SIMD4<Float>],toNeighbor: [SIMD4<Float>],fromNeighbor: [SIMD4<Float>],interval: Float) -> Candidate? {
        let q=p
        guard interval>0,inside(q) else {return nil}
        let local=field(toNeighbor,q),u=vector(local),r=q+u
        guard inside(r),local.z>=0.1,field(fromNeighbor,r).z>=0.1,
              length(u+vector(field(fromNeighbor,r)))<=tolerance,
              cost(source,neighbor,q,r)<=photometricLimit else {return nil}
        let velocity=u*(isFirst ? -1:1)/interval,center=field(central,q)
        guard center.z>=0.1,length(vector(center)-velocity*(isFirst ? 1:-1))<=tolerance else {return nil}
        let end=q+velocity*(isFirst ? 1:-1)
        let closed=inside(end) && length(vector(center)+vector(field(opposite,end)))<=tolerance
        let paired=closed && cost(source,other,q,end)<=photometricLimit
        guard paired || (center.w<0 && !closed) else {return nil}
        return Candidate(q:q,velocity:velocity,paired:paired)
    }
    func render(first: [Float],last: [Float],before: [Float]?,after: [Float]?,forward: [SIMD4<Float>],backward: [SIMD4<Float>],left: VisibilityFields?,right: VisibilityFields?,baseline: [UInt16],decisions: [SIMD4<Float>],t: Float,beforeInterval: Float=1,afterInterval: Float=1,enabled: Bool) -> Output {
        let n=width*height
        precondition(first.count==n && last.count==n && baseline.count==n && decisions.count==n && forward.count==n && backward.count==n && t>=0 && t<=1)
        if let before {precondition(before.count==n)};if let after {precondition(after.count==n)}
        if let left {precondition(left.forward.count==n && left.backward.count==n)};if let right {precondition(right.forward.count==n && right.backward.count==n)}
        var result=Output(pixels:baseline,states:Array(repeating:0,count:n),selected:Array(repeating:0,count:n))
        guard enabled,t>0,t<1 else {return result}
        var ranks=Array(repeating:UInt8(0),count:n),velocities=Array(repeating:SIMD2<Float>.zero,count:n)
        var sums=Array(repeating:Float(0),count:n),weights=Array(repeating:Float(0),count:n)
        var eligible=Array(repeating:false,count:n)
        for k in 0..<n {
            if decisions[k].x>0.5 {result.states[k]=6}
            else if decisions[k].z>0.5 || decisions[k].y<=1e-4 {eligible[k]=true;result.states[k]=4}
        }
        if !eligible.contains(true) || ((before == nil || left == nil) && (after == nil || right == nil)) {return result}
        // A temporally unsupported contour must not expose a different layer behind it.
        var pairedCoverage=Array(repeating:false,count:n)
        for direction in 0..<2 {
            let central=direction==0 ? forward:backward,opposite=direction==0 ? backward:forward,amount=direction==0 ? t:1-t
            for y in 1..<height-1 {for x in 1..<width-1 {
                let q=SIMD2<Float>(Float(x),Float(y)),f=central[y*width+x],v=vector(f),end=q+v
                if f.z<0.1 || !inside(end) || length(v+vector(field(opposite,end)))>tolerance {continue}
                let p=q+amount*v
                if p.x<0 || p.y<0 || p.x>=Float(width-1) || p.y>=Float(height-1) {continue}
                let ix=Int(p.x),iy=Int(p.y),fx=p.x-Float(Int(p.x)),fy=p.y-Float(Int(p.y))
                for dy in 0...1 {for dx in 0...1 {
                    if (dx==0 ? 1-fx:fx)*(dy==0 ? 1-fy:fy)>0 {pairedCoverage[(iy+dy)*width+ix+dx]=true}
                }}
            }}
        }
        func project(_ isFirst:Bool,_ neighbor:[Float]?,_ adjacent:VisibilityFields?,_ interval:Float) {
            guard let neighbor,let adjacent else {return}
            let source=isFirst ? first:last,other=isFirst ? last:first,central=isFirst ? forward:backward,opposite=isFirst ? backward:forward
            let toNeighbor=isFirst ? adjacent.backward:adjacent.forward,fromNeighbor=isFirst ? adjacent.forward:adjacent.backward
            for y in 1..<height-1 {for x in 1..<width-1 {
                let q=SIMD2<Float>(Float(x),Float(y)),u=vector(toNeighbor[y*width+x])
                let v=u*(isFirst ? -1:1)/interval,projected=q+(isFirst ? t:-(1-t))*v
                guard projected.x.isFinite,projected.y.isFinite,projected.x>=0,projected.y>=0,projected.x<Float(width-1),projected.y<Float(height-1) else {continue}
                let ix=Int(projected.x),iy=Int(projected.y)
                guard eligible[iy*width+ix] || eligible[iy*width+ix+1] || eligible[(iy+1)*width+ix] || eligible[(iy+1)*width+ix+1] else {continue}
                guard let c=candidate(isFirst:isFirst,p:q,t:t,source:source,other:other,neighbor:neighbor,central:central,opposite:opposite,toNeighbor:toNeighbor,fromNeighbor:fromNeighbor,interval:interval) else {continue}
                let rank:UInt8=c.paired ? 2:1,state:UInt8=c.paired ? 3:(isFirst ? 1:2)
                let fx=projected.x-Float(ix),fy=projected.y-Float(iy)
                for dy in 0...1 {for dx in 0...1 {
                    let coverage=(dx==0 ? 1-fx:fx)*(dy==0 ? 1-fy:fy),k=(iy+dy)*width+ix+dx
                    if coverage<=0 || !eligible[k] || rank<ranks[k] || (rank==1 && pairedCoverage[k]) {continue}
                    if rank>ranks[k] {ranks[k]=rank;result.states[k]=state;velocities[k]=c.velocity;sums[k]=0;weights[k]=0}
                    else if length(velocities[k]-c.velocity)>tolerance || (rank==1 && result.states[k] != state) {result.states[k]=5}
                    if result.states[k]==5 {continue}
                    let p=SIMD2<Float>(Float(ix+dx),Float(iy+dy)),qa=p-t*c.velocity,qb=p+(1-t)*c.velocity
                    let value:Float
                    if c.paired {value=(1-t)*image(first,qa)+t*image(last,qb)}
                    else {value=image(source,isFirst ? qa:qb)}
                    sums[k]+=coverage*value;weights[k]+=coverage
                }}
            }}
        }
        // Contributions retain their source trajectories; distinct surfaces never average vectors.
        project(true,before,left,beforeInterval);project(false,after,right,afterInterval)
        for k in 0..<n where weights[k]>0 && result.states[k] != 5 {
            result.pixels[k]=UInt16(max(0,min(1023,Int((sums[k]/weights[k]).rounded()))));result.selected[k]=1
        }
        return result
    }
}
