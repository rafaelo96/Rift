import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import Interpolation

// MV_HOLD_CLASSIFY=1: ¿lo que Fluidez máxima no mueve es movimiento rápido que
// una búsqueda mejor recuperaría, o un cambio de pose sin intermedio posible?
// Por par (t = 0.5, repetidos descartados como en Fluidez máxima) compara la
// salida de Fluidez máxima con la salida sin sostén: donde difieren, el sostén
// actuó. En bloques de 16×16 px de esa zona busca una traslación simétrica
// I0(x − s) ≈ I1(x + s) hasta ±160 px por par. Si alguna explica el bloque
// (residuo ≤ 35 % del de no moverse y ≤ 24/1023), es movimiento que una
// interpolación podría seguir; si no, cambio de pose, deformación u oclusión.
// Los bloques en movimiento que sí se interpolaron calibran la prueba.
func classifyHeldMotion(buffers: [CVPixelBuffer], pts: [Double], output: String) throws {
    try FileManager.default.createDirectory(atPath: output,withIntermediateDirectories: true)
    let w=CVPixelBufferGetWidth(buffers[0]),h=CVPixelBufferGetHeight(buffers[0])
    func luma(_ buffer: CVPixelBuffer) -> [Int32] {
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!
        let format=CVPixelBufferGetPixelFormatType(buffer)
        let ten=format==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format==kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var out=[Int32](repeating:0,count:w*h)
        for y in 0..<h {let row=base.advanced(by:y*stride);for x in 0..<w {out[y*w+x]=ten ? Int32(row.assumingMemoryBound(to:UInt16.self)[x]>>6) : Int32(row.assumingMemoryBound(to:UInt8.self)[x])*4}}
        return out
    }
    let config=InterpolationConfig.fluidEconomy.fittingAspect(width:w,height:h)
    let maxFluidity=try MotionCompensator(config:InterpolationConfig(workWidth:config.workWidth,workHeight:config.workHeight,usesDrawingHold:false))
    setenv("RIFT_DRAWING_HOLD","0",1)
    let bare=try MotionCompensator(config:InterpolationConfig(workWidth:config.workWidth,workHeight:config.workHeight,usesDrawingHold:false))
    unsetenv("RIFT_DRAWING_HOLD")
    // Repetidos: misma regla que la simulación (máximo por bloques < 1.5 en 1/3, tope 2).
    let lumas=buffers.map(luma)
    func repeatedLevel(_ a: [Int32],_ b: [Int32]) -> Double {
        var best=0.0
        for by in stride(from:0,to:h-47,by:48) {for bx in stride(from:0,to:w-47,by:48) {
            var s: Int32=0;for y in stride(from:by,to:by+48,by:3) {for x in stride(from:bx,to:bx+48,by:3) {s+=abs(a[y*w+x]-b[y*w+x])}}
            best=max(best,Double(s)/256)
        }}
        return best
    }
    var kept=[0],run=0
    for j in 1..<buffers.count {
        if j<buffers.count-1 && run<2 && repeatedLevel(lumas[kept.last!],lumas[j])<1.5 {run+=1} else {kept.append(j);run=0}
    }
    // Cuarto de resolución para la búsqueda gruesa.
    let qw=w/4,qh=h/4
    func quarter(_ a: [Int32]) -> [Int32] {
        var out=[Int32](repeating:0,count:qw*qh)
        for y in 0..<qh {for x in 0..<qw {var s: Int32=0;for yy in 0..<4 {for xx in 0..<4 {s+=a[(y*4+yy)*w+x*4+xx]}};out[y*qw+x]=s/16}}
        return out
    }
    let quarters=lumas.map(quarter)
    // Búsqueda de un solo lado: el bloque de I0 en su sitio (con textura) contra
    // I1 desplazado hasta ±160 px, y vuelta atrás desde lo encontrado. Una
    // búsqueda simétrica encontraba "coincidencias" entre dos zonas planas
    // cualesquiera del mismo color.
    let block=16,range=160
    func residual(_ a: [Int32],_ b: [Int32],_ ax: Int,_ ay: Int,_ bx: Int,_ by: Int) -> Double? {
        guard min(ax,ay,bx,by)>=0,max(ax,bx)+block<=w,max(ay,by)+block<=h else {return nil}
        var s: Int32=0
        for y in 0..<block {let ra=(ay+y)*w+ax,rb=(by+y)*w+bx;for x in 0..<block {s+=abs(a[ra+x]-b[rb+x])}}
        return Double(s)/Double(block*block)
    }
    func search(_ a: [Int32],_ b: [Int32],_ qa: [Int32],_ qb: [Int32],_ bx: Int,_ by: Int) -> (Int,Int,Double) {
        let qx=bx/4-1,qy=by/4-1,qr=range/4
        var bestQ=Int32.max,cx=0,cy=0
        if qx>=0 && qy>=0 && qx+6<=qw && qy+6<=qh {
            for dy in -qr...qr {for dx in -qr...qr {
                let tx=qx+dx,ty=qy+dy
                guard tx>=0,ty>=0,tx+6<=qw,ty+6<=qh else {continue}
                var s: Int32=0
                for y in 0..<6 {let ra=(qy+y)*qw+qx,rb=(ty+y)*qw+tx;for x in 0..<6 {s+=abs(qa[ra+x]-qb[rb+x])};if s>=bestQ {break}}
                if s<bestQ {bestQ=s;cx=dx*4;cy=dy*4}
            }}
        }
        var best=Double.greatestFiniteMagnitude,fx=0,fy=0
        for dy in cy-4...cy+4 {for dx in cx-4...cx+4 {if let r=residual(a,b,bx,by,bx+dx,by+dy),r<best {best=r;fx=dx;fy=dy}}}
        return (fx,fy,best)
    }
    struct Result {var found: Bool;var flat: Bool;var shift: Double;var best: Double;var still: Double;var sx: Int;var sy: Int}
    func classify(_ i0: Int,_ i1: Int,_ bx: Int,_ by: Int) -> Result {
        let a=lumas[i0],b=lumas[i1]
        var mean=0.0,sq=0.0
        for y in by..<by+block {for x in bx..<bx+block {let v=Double(a[y*w+x]);mean+=v;sq+=v*v}}
        mean/=Double(block*block);let std=(sq/Double(block*block)-mean*mean).squareRoot()
        let still=residual(a,b,bx,by,bx,by) ?? 0
        let (dx,dy,best)=search(a,b,quarters[i0],quarters[i1],bx,by)
        var consistent=false
        if best<=0.35*still && best<=24 {
            let (rx,ry,_)=search(b,a,quarters[i1],quarters[i0],bx+dx,by+dy)
            consistent=abs(rx+dx)<=4 && abs(ry+dy)<=4
        }
        return Result(found:consistent,flat:std<10,shift:hypot(Double(dx),Double(dy)),best:best,still:still,sx:dx,sy:dy)
    }
    let edges=[24.0,64,160]
    func bucket(_ d: Double) -> Int {edges.firstIndex {d<$0} ?? edges.count}
    var heldPx=0,movingPx=0,transitions=0,heldBlocks=[Int](repeating:0,count:6),fineBlocks=[Int](repeating:0,count:6)
    // índices: 0 plano, 1 sin traslación, 2..5 traslación por tamaño (<24, 24–64, 64–160, ≥160)
    var rows=[[String:Any]]()
    let dumpPair=Int(ProcessInfo.processInfo.environment["MV_HOLD_CLASSIFY_DUMP"] ?? "") ?? -1
    var dump=[[Double]]()
    let wanted=Set((ProcessInfo.processInfo.environment["MV_HOLD_CLASSIFY_PNG"] ?? "").split(separator:",").compactMap {Int($0)})
    for p in 1..<kept.count-2 {
        let ia=kept[p],ib=kept[p+1]
        let context=InterpolationTemporalContext(before:buffers[kept[p-1]],after:buffers[kept[p+2]],beforeInterval:Float((pts[ia]-pts[kept[p-1]])/(pts[ib]-pts[ia])),afterInterval:Float((pts[kept[p+2]]-pts[ib])/(pts[ib]-pts[ia])))
        guard let m=maxFluidity.interpolatePair(I0:buffers[ia],I1:buffers[ib],tValues:[0.5],context:context).pixelBuffers.first,
              let n=bare.interpolatePair(I0:buffers[ia],I1:buffers[ib],tValues:[0.5],context:context).pixelBuffers.first,
              m !== buffers[ia],m !== buffers[ib] else {continue}
        let lm=luma(m),ln=luma(n),a=lumas[ia],b=lumas[ib]
        var pairHeld=[Int](repeating:0,count:6),pairFine=[Int](repeating:0,count:6),pairHeldPx=0,pairMovingPx=0
        var overlay=wanted.contains(p) ? lm.map {UInt8(clamping:Int($0)/4)}.flatMap {[$0,$0,$0]} : []
        // Primero todos los bloques en movimiento; luego se exige coherencia: una
        // traslación casual (24 000 candidatos por bloque) no coincide con la de
        // sus vecinos, una real sí.
        struct Cell {var held: Bool;var r: Result;var dx: Int;var dy: Int}
        var cells=[Int:Cell]()
        let cols=w/block
        for by in stride(from:0,to:h-block+1,by:block) {for bx in stride(from:0,to:w-block+1,by:block) {
            var moving=0,held=0
            for y in by..<by+block {for x in bx..<bx+block {
                let k=y*w+x;guard abs(a[k]-b[k])>40 else {continue}
                moving+=1;if abs(lm[k]-ln[k])>8 {held+=1}
            }}
            pairMovingPx+=moving;pairHeldPx+=held
            guard moving>=block*block*3/10 else {continue}
            let r=classify(ia,ib,bx,by)
            cells[(by/block)*cols+bx/block]=Cell(held:held>=moving/3,r:r,dx:r.sx,dy:r.sy)
            if p==dumpPair {dump.append([held>=moving/3 ? 1:0,r.best,r.still,r.shift,r.flat ? 1:0])}
        }}
        for (index,c) in cells {
            var kind=c.r.flat ? 0 : 1
            if !c.r.flat && c.r.found {
                var agree=0
                for (ox,oy) in [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,1),(-1,1),(1,-1)] {
                    if let n=cells[index+oy*cols+ox],n.r.found,!n.r.flat,abs(n.dx-c.dx)<=4,abs(n.dy-c.dy)<=4 {agree+=1}
                }
                if agree>=1 {kind=2+bucket(c.r.shift)}
            }
            if c.held {pairHeld[kind]+=1} else {pairFine[kind]+=1}
            if !overlay.isEmpty && c.held {
                let bx=(index%cols)*block,by=(index/cols)*block
                let tint: (Int,Int,Int)=kind==1 ? (255,40,40) : kind==0 ? (90,90,255) : (40,255,40)
                for y in by..<by+block {for x in bx..<bx+block where y==by || x==bx || y==by+block-1 || x==bx+block-1 {let k=3*(y*w+x);overlay[k]=UInt8(tint.0);overlay[k+1]=UInt8(tint.1);overlay[k+2]=UInt8(tint.2)}}
            }
        }
        // Más de un cuarto del cuadro cambiando: fundido entre planos o corte; no cuenta.
        let transition=pairMovingPx>w*h/4
        if transition {transitions+=1} else {
            for k in 0..<6 {heldBlocks[k]+=pairHeld[k];fineBlocks[k]+=pairFine[k]}
            heldPx+=pairHeldPx;movingPx+=pairMovingPx
        }
        rows.append(["transition":transition,"pair":p,"PTS":[pts[ia],pts[ib]],"held":pairHeld,"fine":pairFine,"heldPixels":pairHeldPx,"movingPixels":pairMovingPx])
        if !overlay.isEmpty {
            let provider=CGDataProvider(data:Data(overlay) as CFData)!
            let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:3*w,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:output+"/pair\(p)-held.png") as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))
        }
    }
    func line(_ name: String,_ v: [Int]) -> String {
        let total=max(1,v.reduce(0,+)),pct={(k: Int) in String(format:"%.0f%%",100*Double(v[k])/Double(total))}
        return "\(name) \(total) bloques: plano \(pct(0)) | sin traslación \(pct(1)) | traslación <24px \(pct(2)) 24–64 \(pct(3)) 64–160 \(pct(4)) ≥160 \(pct(5))"
    }
    print("HOLD CLASSIFY: pares \(rows.count-transitions) de \(kept.count-1) (\(transitions) transiciones fuera); sostenido \(String(format:"%.1f",100*Double(heldPx)/Double(max(1,movingPx))))% de lo que se mueve")
    print("HOLD CLASSIFY "+line("sostenidos",heldBlocks))
    print("HOLD CLASSIFY "+line("interpolados",fineBlocks))
    try confidenceJSON(["dump":dump,"records":rows,"held":heldBlocks,"fine":fineBlocks,"heldPixels":heldPx,"movingPixels":movingPx],output+"/hold-classify.json")
}
