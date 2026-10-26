import Foundation
import Interpolation

// Offline calibration for holding the source drawing where Frame+ finds no
// correspondence. Ground truth is span-2: interpolate (i, i+2) at the real
// time of i+1 and compare with the decoded frame i+1. Per 8x8 work-plane tile,
// compares the Frame+ output against holding the source frame, and records the
// candidate signals. Tooling only; production is unchanged.
func calibrateDrawingHold(lumas: [[UInt16]], w: Int, h: Int, pts: [Double], output: String) throws {
    let config=InterpolationConfig.fluid.fittingAspect(width:w,height:h),ww=config.workWidth,wh=config.workHeight
    let spec=[LevelSpec(width:ww,height:wh,blockSize:config.blockSize,searchHalfPel:8,halfPelRefine:config.subpel,inheritFactor:4),
              LevelSpec(width:ww/2,height:wh/2,blockSize:16,searchHalfPel:16,halfPelRefine:false,inheritFactor:2),
              LevelSpec(width:ww/4,height:wh/4,blockSize:16,searchHalfPel:32,halfPelRefine:false,inheritFactor:2),
              LevelSpec(width:ww/8,height:wh/8,blockSize:16,searchHalfPel:32,halfPelRefine:false,inheritFactor:1)]
    let forwardME=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:config.lambdaPx,smoothL0:true,gateL0:true,temporalGatePx:0)
    let reverseME=try MotionSearchEngine(msl:motionShadersMSL,spec:spec,lambdaPx:config.lambdaPx,smoothL0:true,gateL0:true,temporalGatePx:0)
    let dense=try DenseMotionPrototype(width:ww,height:wh,blockSize:config.blockSize,inverseSearch:true)
    func work(_ l: [UInt16]) -> [UInt16] {
        var out=[UInt16](repeating:0,count:ww*wh)
        for y in 0..<wh {for x in 0..<ww {
            let x0=x*w/ww,x1=max(x0+1,(x+1)*w/ww),y0=y*h/wh,y1=max(y0+1,(y+1)*h/wh)
            var sum=0;for yy in y0..<y1 {for xx in x0..<x1 {sum+=Int(l[yy*w+xx])}}
            out[y*ww+x]=UInt16(sum/((x1-x0)*(y1-y0)))
        }}
        return out
    }
    let works=lumas.map(work)
    let tile=8,tw=ww/tile,th=wh/tile
    let unmatchedThresholds: [Float]=[0.1,0.2,0.3,0.5,0.7],residualThresholds=[16,24,32,48,64]
    if ProcessInfo.processInfo.environment["MV_HOLD_PREVIEW"]=="1" {
        // Span-1 preview as production would see it: current Frame+ luma vs holding the
        // nearest source in tiles whose unmatched fraction > 0.3 (dilated one tile).
        for i in 0..<works.count-1 {
            let a=works[i],b=works[i+1],ad=a.withUnsafeBytes {Data($0)},bd=b.withUnsafeBytes {Data($0)}
            _=try forwardME.runPairBatched(cur:ad,ref:bd);let f=forwardME.downloadMV(level:0)
            _=try reverseME.runPairBatched(cur:bd,ref:ad);let r=reverseME.downloadMV(level:0)
            let result=try dense.interpolate(first:ad,last:bd,forward:f,backward:r,time:0.5)
            var flag=[Bool](repeating:false,count:tw*th)
            for ty in 0..<th {for tx in 0..<tw {
                var u=0
                for y in ty*tile..<ty*tile+tile {for x in tx*tile..<tx*tile+tile where result.reliability[y*ww+x]<0.02 {u+=1}}
                flag[ty*tw+tx]=Float(u)/Float(tile*tile)>0.3
            }}
            var held=result.pixels,count=0
            for ty in 0..<th {for tx in 0..<tw {
                var on=false
                for dy in -1...1 {for dx in -1...1 {let x=tx+dx,y=ty+dy;if x>=0,y>=0,x<tw,y<th,flag[y*tw+x] {on=true}}}
                if on {count+=1;for y in ty*tile..<ty*tile+tile {for x in tx*tile..<tx*tile+tile {held[y*ww+x]=a[y*ww+x]}}}
            }}
            confidencePNG(result.pixels,ww,wh,output+"/preview\(i)-current.png")
            confidencePNG(held,ww,wh,output+"/preview\(i)-hold.png")
            print("PREVIEW \(i): held \(String(format:"%.1f",100*Double(count)/Double(tw*th)))% of tiles")
        }
        return
    }
    var rows=[[String:Any]]()
    for i in 0..<works.count-2 {
        let a=works[i],truth=works[i+1],b=works[i+2]
        let t=Float((pts[i+1]-pts[i])/(pts[i+2]-pts[i]))
        let ad=a.withUnsafeBytes {Data($0)},bd=b.withUnsafeBytes {Data($0)}
        _=try forwardME.runPairBatched(cur:ad,ref:bd);let f=forwardME.downloadMV(level:0)
        _=try reverseME.runPairBatched(cur:bd,ref:ad);let r=reverseME.downloadMV(level:0)
        let result=try dense.interpolate(first:ad,last:bd,forward:f,backward:r,time:t)
        // Signal B: level-1 motion-compensated residual of the 16x16 block (32x32 work pixels).
        let l1a=forwardME.readLevel(1),l1b=reverseME.readLevel(1),mv1=forwardME.downloadMV(level:1),g1=forwardME.grids[1],lw=ww/2,lh=wh/2
        var blockResidual=[Double](repeating:0,count:g1.w*g1.h)
        for by in 0..<g1.h {for bx in 0..<g1.w {
            let v=mv1[by*g1.w+bx],dx=Int(v.x)/2,dy=Int(v.y)/2;var sum=0,n=0
            for y in by*16..<min(by*16+16,lh) {for x in bx*16..<min(bx*16+16,lw) {
                sum+=abs(Int(l1a[y*lw+x])-Int(l1b[min(max(y+dy,0),lh-1)*lw+min(max(x+dx,0),lw-1)]));n+=1
            }}
            blockResidual[by*g1.w+bx]=Double(sum)/Double(max(n,1))
        }}
        var interpErr=[Double](),holdErr=[Double](),holdFirst=[Double](),holdLast=[Double](),unmatched=[Float](),residual=[Double]()
        for ty in 0..<th {for tx in 0..<tw {
            var ei=0,e0=0,e1=0,u=0
            for y in ty*tile..<ty*tile+tile {for x in tx*tile..<tx*tile+tile {
                let k=y*ww+x,g=Int(truth[k])
                ei+=abs(Int(result.pixels[k])-g);e0+=abs(Int(a[k])-g);e1+=abs(Int(b[k])-g)
                if result.reliability[k]<0.02 {u+=1}
            }}
            let n=Double(tile*tile)
            interpErr.append(Double(ei)/n);holdErr.append(Double(t<=0.5 ? e0:e1)/n);holdFirst.append(Double(e0)/n);holdLast.append(Double(e1)/n)
            unmatched.append(Float(u)/Float(tile*tile))
            residual.append(blockResidual[min(ty*tile/32,g1.h-1)*g1.w+min(tx*tile/32,g1.w-1)])
        }}
        let n=Double(interpErr.count)
        // Span-2 on animation drawn on twos: the true middle frame repeats one of the
        // two endpoint drawings, so "pair" picks ONE endpoint for the whole pair (the
        // better one), a source frame either way; "nearest" is the t<=0.5 rule.
        func evaluate(_ held: (Int)->Bool) -> [String:Double] {
            var maeNearest=0.0,maeFirst=0.0,maeLast=0.0,count=0,worseNearest=0,worseFirst=0,worseLast=0
            for k in interpErr.indices {
                if held(k) {
                    count+=1;maeNearest+=holdErr[k];maeFirst+=holdFirst[k];maeLast+=holdLast[k]
                    if holdErr[k]>interpErr[k]+8 {worseNearest+=1}
                    if holdFirst[k]>interpErr[k]+8 {worseFirst+=1}
                    if holdLast[k]>interpErr[k]+8 {worseLast+=1}
                } else {maeNearest+=interpErr[k];maeFirst+=interpErr[k];maeLast+=interpErr[k]}
            }
            let first=maeFirst<=maeLast
            return ["mae":maeNearest/n,"maePair":min(maeFirst,maeLast)/n,"held":Double(count)/n,
                    "heldWorse":Double(worseNearest)/n,"heldWorsePair":Double(first ? worseFirst:worseLast)/n]
        }
        var candidates=[String:[String:Double]]()
        for u in unmatchedThresholds {candidates["unmatched>\(u)"]=evaluate {unmatched[$0]>u}}
        for q in residualThresholds {candidates["residual>\(q)"]=evaluate {residual[$0]>Double(q)}}
        rows.append(["triple":i,"PTS":[pts[i],pts[i+1],pts[i+2]],"t":t,
                     "interpMAE":interpErr.reduce(0,+)/n,"oracleMAE":zip(interpErr,holdErr).map {min($0,$1)}.reduce(0,+)/n,
                     "holdAllMAE":holdErr.reduce(0,+)/n,"holdPairMAE":min(holdFirst.reduce(0,+),holdLast.reduce(0,+))/n,"holdBetterTiles":Double(zip(interpErr,holdErr).filter {$1+8<$0}.count)/n,
                     "candidates":candidates])
        print("HOLD \(i): interp \(String(format:"%.2f",interpErr.reduce(0,+)/n)) hold-better tiles \(String(format:"%.1f",100*Double(zip(interpErr,holdErr).filter {$1+8<$0}.count)/n))%")
    }
    try confidenceJSON(["width":w,"height":h,"workWidth":ww,"workHeight":wh,"tile":tile,"truth":"span-2 middle frame","records":rows],output+"/hold-calibration.json")
}
