import Foundation
import Metal

/// Experimental F2 final-field filter. Owned by one serialized pair processor.
/// shortcut: luminance guidance cannot separate equal-luma motion boundaries.
final class FramePlusEdgeRegularizer {
    private let guidePipeline: MTLComputePipelineState
    private let medianPipeline: MTLComputePipelineState
    private let guides: [MTLTexture]
    private let outputs: [MTLTexture]

    init(device: MTLDevice, width: Int, height: Int) throws {
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        kernel void blockGuide(texture2d<uint,access::read> a [[texture(0)]],texture2d<float,access::write> g [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=g.get_width()||p.y>=g.get_height())return;float sum=0,n=0;
            for(uint y=p.y*8;y<min(a.get_height(),p.y*8+8);++y)for(uint x=p.x*8;x<min(a.get_width(),p.x*8+8);++x){sum+=a.read(uint2(x,y)).r;n+=1;}
            g.write(float4(sum/(n*1023)),p);
        }
        float weightedMedian(thread float *v,thread float *w,float total) {
            for(int i=1;i<9;++i){float a=v[i],b=w[i];int j=i-1;while(j>=0&&v[j]>a){v[j+1]=v[j];w[j+1]=w[j];--j;}v[j+1]=a;w[j+1]=b;}
            float acc=0;for(int i=0;i<9;++i){acc+=w[i];if(acc>=total*0.5f)return v[i];}return v[8];
        }
        kernel void edgeMedian(texture2d<float,access::read> f [[texture(0)]],texture2d<float,access::read> guide [[texture(1)]],texture2d<float,access::write> out [[texture(2)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=f.get_width()||p.y>=f.get_height())return;int2 c=int2(p/8);float center=guide.read(uint2(c)).r;float vx[9],vy[9],wx[9],wy[9],total=0;int k=0;
            for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=clamp(c+int2(x,y),int2(0),int2(guide.get_width()-1,guide.get_height()-1));float dl=guide.read(uint2(q)).r-center;
                float weight=abs(dl)>0.06f ? 0 : exp(-0.5f*(x*x+y*y)-0.5f*(dl/0.02f)*(dl/0.02f));
                int2 pixel=clamp(int2(p)+int2(x,y)*8,int2(0),int2(f.get_width()-1,f.get_height()-1));float2 value=f.read(uint2(pixel)).xy;
                vx[k]=value.x;vy[k]=value.y;wx[k]=weight;wy[k]=weight;total+=weight;++k;}
            float4 original=f.read(p);original.xy=float2(weightedMedian(vx,wx,total),weightedMedian(vy,wy,total));out.write(original,p);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let guide = library.makeFunction(name: "blockGuide"),
              let median = library.makeFunction(name: "edgeMedian") else {
            throw MotionSearchEngine.EngineError.pipeline("F2 kernels unavailable")
        }
        guidePipeline = try device.makeComputePipelineState(function: guide)
        medianPipeline = try device.makeComputePipelineState(function: median)
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw MotionSearchEngine.EngineError.pipeline("F2 allocation failed")
            }
            return texture
        }
        guides = try (0..<2).map { _ in try texture(.r32Float, (width+7)/8, (height+7)/8) }
        outputs = try (0..<2).map { _ in try texture(.rgba32Float, width, height) }
    }

    func encode(command: MTLCommandBuffer, fields: [MTLTexture], luma: [MTLTexture]) throws -> [MTLTexture] {
        for direction in 0..<2 {
            for (pipeline, textures, target) in [
                (guidePipeline, [luma[direction], guides[direction]], guides[direction]),
                (medianPipeline, [fields[direction], guides[direction], outputs[direction]], outputs[direction])
            ] {
                guard let encoder = command.makeComputeCommandEncoder() else {
                    throw MotionSearchEngine.EngineError.pipeline("F2 encoder unavailable")
                }
                encoder.setComputePipelineState(pipeline)
                for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
                encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
            }
        }
        return outputs
    }
}
