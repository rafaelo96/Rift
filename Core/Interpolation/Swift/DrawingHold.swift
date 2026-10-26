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

final class DrawingHold {
    static let radius = 16
    /// El contenido que entra o sale por el borde no tiene correspondencia en ningún
    /// paneo; no es un redibujo, así que la banda del borde nunca siembra el sostén.
    static let borderMargin = 16
    private let pipelines: [String: MTLComputePipelineState]
    private let horizontal: MTLTexture
    private let mask: MTLTexture
    private let width: Int, height: Int

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width; self.height = height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let horizontal = device.makeTexture(descriptor: descriptor),
              let mask = device.makeTexture(descriptor: descriptor) else {
            throw MotionSearchEngine.EngineError.pipeline("Drawing hold texture allocation failed")
        }
        self.horizontal = horizontal; self.mask = mask
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        constant int R = \(DrawingHold.radius);
        constant int M = \(DrawingHold.borderMargin);
        kernel void holdDensityX(texture2d<float,access::read> reliability [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
            int w=reliability.get_width(),h=reliability.get_height(); if(p.x>=uint(w)||p.y>=uint(h)) return;
            bool rowInside=int(p.y)>=M && int(p.y)<h-M;
            float sum=0,n=0;
            for(int d=-R;d<=R;++d) { int x=int(p.x)+d; if(x<0||x>=w) continue; sum+=rowInside && x>=M && x<w-M && reliability.read(uint2(x,p.y)).r<0.02f ? 1 : 0; n+=1; }
            output.write(sum/n,p);
        }
        kernel void holdDensityY(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::write> mask [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
            int h=input.get_height(); if(p.x>=input.get_width()||p.y>=uint(h)) return;
            float sum=0,n=0;
            for(int d=-R;d<=R;++d) { int y=int(p.y)+d; if(y<0||y>=h) continue; sum+=input.read(uint2(p.x,y)).r; n+=1; }
            mask.write(smoothstep(0.05f,0.15f,sum/n),p);
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
        for name in ["holdDensityX", "holdDensityY", "holdApply"] {
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
        try dispatch("holdDensityX", [reliability, horizontal])
        try dispatch("holdDensityY", [horizontal, mask])
        var t = time
        try dispatch("holdApply", [mask, coordinates, blend, output, images[0], images[1]]) {
            $0.setBytes(&t, length: MemoryLayout<Float>.stride, index: 0)
        }
    }
}
