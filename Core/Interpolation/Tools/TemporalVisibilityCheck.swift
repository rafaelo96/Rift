import Foundation

func checkTemporalVisibility() -> [[String:Any]] {
    let w=96,h=64,n=w*h,renderer=TemporalVisibility(width:w,height:h)
    var rows=[[String:Any]]()
    for dx in [Float(0),8,16] {
        func foreground(_ x: Float,_ y: Float,_ time: Float)->Bool {x>=32+time*dx && x<48+time*dx && y>=20 && y<44}
        func scene(_ time: Float)->[Float] {(0..<n).map {k in
            let x=k%w,y=k/w
            return foreground(Float(x),Float(y),time) ? Float(650+(Int(Float(x)-time*dx)*7+y*13)%100):Float(100+(x*17+y*11)%80)
        }}
        func field(_ from: Float,_ to: Float)->[SIMD4<Float>] {(0..<n).map {k in
            let x=Float(k%w),y=Float(k/w),fg=foreground(x,y,from),v=fg ? (to-from)*dx:0
            let hidden=foreground(x+v,y,to) != fg
            return SIMD4(v,0,1,hidden ? -1:0)
        }}
        let a=scene(0),b=scene(1),before=scene(-1),after=scene(2),f=field(0,1),r=field(1,0)
        let left=VisibilityFields(forward:field(-1,0),backward:field(0,-1)),right=VisibilityFields(forward:field(1,2),backward:field(2,1))
        let flags=Array(repeating:SIMD4<Float>(0,0,1,0.5),count:n)
        for t:Float in [0.25,0.5,0.75] {
            let truth=scene(t),base=Array(repeating:UInt16(0),count:n)
            let result=renderer.render(first:a,last:b,before:before,after:after,forward:f,backward:r,left:left,right:right,baseline:base,decisions:flags,t:t,enabled:true)
            var count=0,error:Float=0,maxError:Float=0,states=[Int](repeating:0,count:7)
            for k in 0..<n {states[Int(result.states[k])]+=1;if result.selected[k]>0 {let e=abs(Float(result.pixels[k])-truth[k]);error+=e;maxError=max(maxError,e);count+=1}}
            print("VISIBILITY SYNTH dx=\(dx) t=\(t) selected=\(count) maxError=\(maxError)")
            precondition(count>n/2 && maxError<=2,"Visibility reconstruction crossed a known surface")
            let off=renderer.render(first:a,last:b,before:before,after:after,forward:f,backward:r,left:left,right:right,baseline:base,decisions:flags,t:t,enabled:false)
            precondition(off.pixels==base && off.selected.allSatisfy{$0==0})
            let missing=renderer.render(first:a,last:b,before:nil,after:nil,forward:f,backward:r,left:nil,right:nil,baseline:base,decisions:flags,t:t,enabled:true)
            precondition(missing.pixels==base && missing.selected.allSatisfy{$0==0},"Missing evidence manufactured motion")
            let stillFlags=Array(repeating:SIMD4<Float>(1,1,1,0),count:n),original=a.map{UInt16($0)}
            let still=renderer.render(first:a,last:b,before:before,after:after,forward:f,backward:r,left:left,right:right,baseline:original,decisions:stillFlags,t:t,enabled:true)
            precondition(still.pixels==original && still.selected.allSatisfy{$0==0},"Static protection changed")
            let mismatched=renderer.render(first:a,last:b,before:before.map{$0+200},after:after.map{$0+200},forward:f,backward:r,left:left,right:right,baseline:base,decisions:flags,t:t,enabled:true)
            precondition(mismatched.pixels==base && mismatched.selected.allSatisfy{$0==0},"Photometrically wrong neighbors supplied false visibility")
            rows.append(["dx":dx,"t":t,"selected":count,"selectedMAE":error/Float(count),"maxError":maxError,"states":states,"disabledExact":true,"noNeighborExact":true,"staticExact":true])
        }
    }
    let a=Array(repeating:Float(100),count:n),b=Array(repeating:Float(700),count:n),base=Array(repeating:UInt16(777),count:n)
    func constant(_ x:Float,_ hidden:Bool=false)->[SIMD4<Float>] {Array(repeating:SIMD4<Float>(x,0,1,hidden ? -1:0),count:n)}
    let ambiguous=renderer.render(first:a,last:b,before:a,after:b,forward:constant(8,true),backward:constant(-4,true),left:VisibilityFields(forward:constant(8),backward:constant(-8)),right:VisibilityFields(forward:constant(4),backward:constant(-4)),baseline:base,decisions:Array(repeating:SIMD4<Float>(0,0,1,0.5),count:n),t:0.5,enabled:true)
    let ambiguousInterior=(4..<h-4).flatMap{y in (16..<w-16).map{y*w+$0}}
    precondition(ambiguousInterior.allSatisfy{ambiguous.states[$0]==5 && ambiguous.selected[$0]==0 && ambiguous.pixels[$0]==base[$0]},"Competing unilateral surfaces were guessed")
    for t:Float in [0,1] {
        let endpoint=renderer.render(first:a,last:b,before:nil,after:nil,forward:constant(0),backward:constant(0),left:nil,right:nil,baseline:base,decisions:Array(repeating:.zero,count:n),t:t,enabled:true)
        precondition(endpoint.pixels==base && endpoint.selected.allSatisfy{$0==0})
    }
    print("VISIBILITY CHECK: nine exact-layer translation/cover/uncover controls; disabled, static and missing-neighbor identity passed")
    return rows
}
