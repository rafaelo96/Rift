import Metal

// MARK: - DrawingHold
//
// Animación dibujada en "dos": entre dos frames fuente el dibujo del personaje
// cambia (otra pose), no se desplaza. No existe correspondencia que warpear y
// Frame+ lo despedaza en parches. Donde la síntesis densa no encuentra
// correspondencia (reliability < 0.02), la densidad local de esos píxeles
// (caja 33×33 en el work-plane, sin contar la banda del borde del frame) define
// un peso suave h = smoothstep(0.05, 0.15) y la salida se lleva hacia el frame
// fuente más cercano sin desplazamiento: vectores × (1−h), mezcla → 0 (t ≤ 0.5) o 1. Con h = 0 nada se escribe, así
// que los píxeles lejos de esas zonas quedan idénticos byte a byte.
// Calibrado/visto offline (MVProbe MV_HOLD_CALIBRATION / MV_HOLD_NATIVE_PREVIEW).
// RIFT_DRAWING_HOLD=0 lo desactiva.
//
// Segunda siembra, por daño: la falta de correspondencia no cubre todo lo que
// sale roto. Un cambio de pose también deja píxeles "con correspondencia" que
// mezclan dos superficies distintas o que saltan de un sitio a otro entre
// vecinos (el aspecto de parches). Se siembra donde las dos muestras que se
// mezclan difieren (media 3×3 > 0.04) o donde el mapa de coordenadas salta más
// de 2 px entre píxeles contiguos; su densidad en la misma caja da
// h = smoothstep(0.05, 0.12). Un paneo rígido no siembra nada. Esta siembra
// queda activa también en "fluidez máxima" (que solo quita la primera).
// E07 1080p, M4, 3 tramos de ~100 pares: píxeles "lejos de ambos" frente al
// sostén anterior 0.183 → 0.116 %*, 0.167 → 0.027 %, 0.658 → 0.19 %
// (*tramo de 14 pares de 9:50: 0.49 → 0.12 %, peor par 1.9 → 0.34 %).
// RIFT_HOLD_DAMAGE=0 la quita (comportamiento anterior).

final class DrawingHold {
    static let radius = 16
    /// El contenido que entra o sale por el borde no tiene correspondencia en ningún
    /// paneo; no es un redibujo, así que la banda del borde nunca siembra el sostén.
    static let borderMargin = 16
    private let pipelines: [String: MTLComputePipelineState]
    private let seeds: MTLTexture
    private let horizontal: MTLTexture
    private let mask: MTLTexture
    private let width: Int, height: Int
    /// x: 1 = siembra por falta de correspondencia; y: 1 = siembra por daño.
    private var seedKinds: SIMD2<Float>

    init(device: MTLDevice, width: Int, height: Int, unmatchedSeed: Bool = true, damageSeed: Bool = true) throws {
        self.width = width; self.height = height
        let env = ProcessInfo.processInfo.environment
        seedKinds = SIMD2(unmatchedSeed && env["RIFT_HOLD_UNMATCHED"] != "0" ? 1 : 0,
                          damageSeed && env["RIFT_HOLD_DAMAGE"] != "0" ? 1 : 0)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        maskDescriptor.storageMode = .private
        maskDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let seeds = device.makeTexture(descriptor: descriptor),
              let horizontal = device.makeTexture(descriptor: descriptor),
              let mask = device.makeTexture(descriptor: maskDescriptor) else {
            throw MotionSearchEngine.EngineError.pipeline("Drawing hold texture allocation failed")
        }
        self.seeds = seeds; self.horizontal = horizontal; self.mask = mask
        let mismatch = Float(env["RIFT_HOLD_MISMATCH"] ?? "") ?? 0.04
        let jump = Float(env["RIFT_HOLD_JUMP"] ?? "") ?? 2
        let damageLow = Float(env["RIFT_HOLD_DAMAGE_LOW"] ?? "") ?? 0.05
        let damageHigh = Float(env["RIFT_HOLD_DAMAGE_HIGH"] ?? "") ?? 0.12
        let damageRadius = Int(env["RIFT_HOLD_DAMAGE_RADIUS"] ?? "") ?? DrawingHold.radius
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        constant int R = \(DrawingHold.radius);
        constant int M = \(DrawingHold.borderMargin);
        constant float MISMATCH = \(mismatch);
        constant float JUMP = \(jump);
        constant float DAMAGE_LOW = \(damageLow);
        constant float DAMAGE_HIGH = \(damageHigh);
        constant int RD = \(damageRadius);
        static float holdRead(texture2d<float,access::read> image,float2 q) {
            int w=image.get_width(),h=image.get_height();
            return image.read(uint2(clamp(int(q.x+0.5f),0,w-1),clamp(int(q.y+0.5f),0,h-1))).r;
        }
        // r: sin correspondencia (reliability < 0.02). g: daño visible en lo ya
        // sintetizado: las dos muestras que se mezclan no son la misma superficie,
        // o el mapa de coordenadas salta entre píxeles vecinos (parches).
        kernel void holdSeed(texture2d<float,access::read> reliability [[texture(0)]],texture2d<float,access::read> coordinates [[texture(1)]],texture2d<float,access::read> blend [[texture(2)]],texture2d<float,access::read> first [[texture(3)]],texture2d<float,access::read> last [[texture(4)]],texture2d<float,access::write> seeds [[texture(5)]],constant float2 &kinds [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
            int w=reliability.get_width(),h=reliability.get_height(); if(p.x>=uint(w)||p.y>=uint(h)) return;
            bool inside=int(p.x)>=M && int(p.x)<w-M && int(p.y)>=M && int(p.y)<h-M;
            if(!inside) { seeds.write(float4(0),p); return; }
            float unmatched=kinds.x>0 && reliability.read(p).r<0.02f ? 1 : 0;
            float damage=0;
            if(kinds.y>0) {
                float4 c=coordinates.read(p); float alpha=blend.read(p).r; float2 q=float2(p);
                if(alpha>0.02f && alpha<0.98f) {
                    float cost=0;
                    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) { float2 d=float2(x,y); cost+=abs(holdRead(first,q+c.xy+d)-holdRead(last,q+c.zw+d)); }
                    if(cost/9>MISMATCH) damage=1;
                }
                float4 right=coordinates.read(uint2(p.x+1,p.y)),down=coordinates.read(uint2(p.x,p.y+1));
                float jump=max(max(length(c.xy-right.xy),length(c.zw-right.zw)),max(length(c.xy-down.xy),length(c.zw-down.zw)));
                if(jump>JUMP) damage=1;
            }
            seeds.write(float4(unmatched,damage,0,0),p);
        }
        kernel void holdDensityX(texture2d<float,access::read> seeds [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
            int w=seeds.get_width(),h=seeds.get_height(); if(p.x>=uint(w)||p.y>=uint(h)) return;
            float2 sum=0,n=0;
            for(int d=-R;d<=R;++d) { int x=int(p.x)+d; if(x<0||x>=w) continue; float2 s=seeds.read(uint2(x,p.y)).rg; sum.x+=s.x; n.x+=1; if(abs(d)<=RD) { sum.y+=s.y; n.y+=1; } }
            output.write(float4(sum/n,0,0),p);
        }
        kernel void holdDensityY(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::write> mask [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
            int h=input.get_height(); if(p.x>=input.get_width()||p.y>=uint(h)) return;
            float2 sum=0,n=0;
            for(int d=-R;d<=R;++d) { int y=int(p.y)+d; if(y<0||y>=h) continue; float2 s=input.read(uint2(p.x,y)).rg; sum.x+=s.x; n.x+=1; if(abs(d)<=RD) { sum.y+=s.y; n.y+=1; } }
            float2 density=sum/n;
            mask.write(max(smoothstep(0.05f,0.15f,density.x),smoothstep(DAMAGE_LOW,DAMAGE_HIGH,density.y)),p);
        }
        kernel void holdApply(texture2d<float,access::read> mask [[texture(0)]],texture2d<float,access::read_write> coordinates [[texture(1)]],texture2d<float,access::read_write> blend [[texture(2)]],texture2d<uint,access::read_write> output [[texture(3)]],texture2d<float,access::read> first [[texture(4)]],texture2d<float,access::read> last [[texture(5)]],constant float &t [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=mask.get_width()||p.y>=mask.get_height()||t==0||t==1) return;
            float h=mask.read(p).r; if(h<=0) return;
            float nearest=t<=0.5f ? 0 : 1;
            coordinates.write(coordinates.read(p)*(1-h),p);
            blend.write(mix(blend.read(p).r,nearest,h),p);
            float source=t<=0.5f ? first.read(p).r : last.read(p).r;
            output.write(uint(clamp(mix(float(output.read(p).r)/1023.0f,source,h),0.0f,1.0f)*1023+0.5f),p);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        var compiled = [String: MTLComputePipelineState]()
        for name in ["holdSeed", "holdDensityX", "holdDensityY", "holdApply"] {
            guard let function = library.makeFunction(name: name) else { throw MotionSearchEngine.EngineError.pipeline("Missing \(name)") }
            compiled[name] = try device.makeComputePipelineState(function: function)
        }
        pipelines = compiled
    }

    /// Encodes after `denseSynthesize` and before the native renderer consumes coordinates/blend.
    func encode(command: MTLCommandBuffer, reliability: MTLTexture, images: [MTLTexture],
                coordinates: MTLTexture, blend: MTLTexture, output: MTLTexture, time: Float) throws {
        guard time > 0, time < 1 else { return }
        func dispatch(_ name: String, _ textures: [MTLTexture], _ setup: (MTLComputeCommandEncoder) -> Void = { _ in }) throws {
            guard let encoder = command.makeComputeCommandEncoder(), let pipeline = pipelines[name] else {
                throw MotionSearchEngine.EngineError.pipeline("Drawing hold encoder allocation failed")
            }
            encoder.setComputePipelineState(pipeline)
            for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
            setup(encoder)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding()
        }
        var kinds = seedKinds
        try dispatch("holdSeed", [reliability, coordinates, blend, images[0], images[1], seeds]) {
            $0.setBytes(&kinds, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        try dispatch("holdDensityX", [seeds, horizontal])
        try dispatch("holdDensityY", [horizontal, mask])
        var t = time
        try dispatch("holdApply", [mask, coordinates, blend, output, images[0], images[1]]) {
            $0.setBytes(&t, length: MemoryLayout<Float>.stride, index: 0)
        }
    }
}
