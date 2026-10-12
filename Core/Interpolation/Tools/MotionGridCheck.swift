import Foundation
import Metal
import Interpolation

func checkWarpMotionContinuity() throws {
    let width = 32, height = 24
    let engine = try WarpEngine(msl: warpShadersMSL)
    var first = [UInt16](repeating: 64, count: width*height)
    var last = first
    first[12*width+8] = 960
    last[12*width+16] = 960
    let field = [SIMD2<Int32>](repeating: SIMD2<Int32>(16,0), count: 12)
    for time: Float in [0,0.25,0.5,0.75,1] {
        let result = engine.interpolate(I0: first, I1: last, mv: field, width: width, height: height, gridW: 4, gridH: 3, blockSize: 8, t: time).0
        var expected = [UInt16](repeating: 64, count: width*height)
        expected[12*width+8+Int(time*8)] = 960
        let error = zip(result,expected).map { abs(Int($0)-Int($1)) }.max() ?? Int.max
        print("WARP MOTION: t=\(time), maximum error=\(error)")
        guard result == expected else { throw WarpEngine.Error.pipeline("Moving point disappeared or warped incorrectly") }
    }
    let still = engine.interpolate(I0: first, I1: first, mv: field, width: width, height: height, gridW: 4, gridH: 3, blockSize: 8, t: 0.5).0
    precondition(still == first, "Static content protection regressed")
    try checkNativeAndChromaTransport()
}

private func checkNativeAndChromaTransport() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw WarpEngine.Error.deviceUnavailable }
    let library = try device.makeLibrary(source: warpShadersMSL, options: nil)
    let variants: [(name: String, channels: Int, subsampleY: Int)] = [
        ("warpBlendNative",1,1), ("warpBlendChromaNative",2,2),
        ("warpBlendChromaNative",2,1), ("warpBlendChroma2",2,2)
    ]
    for variant in variants {
        let width = variant.channels == 1 ? 32 : 16
        let height = 24 / variant.subsampleY
        let shift = variant.channels == 1 ? 8 : 4
        let startX = variant.channels == 1 ? 8 : 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: variant.channels == 1 ? .r16Uint : .rg16Uint, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead,.shaderWrite]
        guard let function = library.makeFunction(name: variant.name), let a = device.makeTexture(descriptor: descriptor),
              let b = device.makeTexture(descriptor: descriptor), let output = device.makeTexture(descriptor: descriptor) else { throw WarpEngine.Error.pipeline("transport texture allocation failed") }
        let pipeline = try device.makeComputePipelineState(function: function)
        let field = [SIMD2<Int32>](repeating: SIMD2<Int32>(16,0), count: 12)
        guard let mv = device.makeBuffer(bytes: field, length: field.count*MemoryLayout<SIMD2<Int32>>.stride) else { throw WarpEngine.Error.pipeline("transport vector allocation failed") }
        for scale: UInt16 in [1,64] {
            var source = [UInt16](repeating: 64*scale, count: width*height*variant.channels)
            for channel in 0..<variant.channels { source[(6*width+startX)*variant.channels+channel] = (960-UInt16(channel)*80)*scale }
            var target = [UInt16](repeating: 64*scale, count: source.count)
            for channel in 0..<variant.channels { target[(6*width+startX+shift)*variant.channels+channel] = (960-UInt16(channel)*80)*scale }
            let region = MTLRegionMake2D(0,0,width,height)
            for isStatic in [false,true] {
                source.withUnsafeBytes { a.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width*variant.channels*2) }
                let second = isStatic ? source : target
                second.withUnsafeBytes { b.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width*variant.channels*2) }
                for time: Float in [0,0.25,0.5,0.75,1] {
                    var uniforms: [UInt32]
                    if variant.name == "warpBlendChroma2" {
                        uniforms = [UInt32(width),UInt32(height),4,3,8,time.bitPattern,Float(1).bitPattern]
                    } else {
                        uniforms = [UInt32(width),UInt32(height),32,24,4,3,8,0,UInt32(variant.subsampleY),time.bitPattern,Float(1).bitPattern]
                    }
                    guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw WarpEngine.Error.pipeline("transport command allocation failed") }
                    encoder.setComputePipelineState(pipeline)
                    encoder.setTexture(a,index: 0)
                    encoder.setTexture(b,index: 1)
                    encoder.setTexture(output,index: 2)
                    encoder.setBuffer(mv,offset: 0,index: 0)
                    uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
                    encoder.dispatchThreads(MTLSize(width: width,height: height,depth: 1), threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
                    encoder.endEncoding()
                    command.commit()
                    command.waitUntilCompleted()
                    guard command.status == .completed else { throw WarpEngine.Error.pipeline("transport GPU command failed") }
                    var actual = [UInt16](repeating: 0,count: source.count)
                    actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width*variant.channels*2, from: region, mipmapLevel: 0) }
                    var expected = [UInt16](repeating: 64*scale,count: source.count)
                    let position = startX + (isStatic ? 0 : Int(time*Float(shift)))
                    for channel in 0..<variant.channels { expected[(6*width+position)*variant.channels+channel] = (960-UInt16(channel)*80)*scale }
                    guard actual == expected else { throw WarpEngine.Error.pipeline("\(variant.name) transport mismatch, subsampleY=\(variant.subsampleY), scale=\(scale), static=\(isStatic), t=\(time)") }
                }
            }
        }
        print("WARP TRANSPORT: \(variant.name), subsampleY=\(variant.subsampleY) — motion and static checks passed at both numeric scales")
    }
}

func checkMotionGridRegistration() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw WarpEngine.Error.deviceUnavailable
    }
    let shader = warpShadersMSL + """

    kernel void probeMotionGrid(device const int2 *mv [[buffer(0)]],
                                device const float2 *points [[buffer(1)]],
                                device float2 *output [[buffer(2)]],
                                uint i [[thread_position_in_grid]]) {
        output[i] = sampleMVBilinear(mv, points[i], 4, 3, 8);
    }
    """
    let library = try device.makeLibrary(source: shader, options: nil)
    guard let function = library.makeFunction(name: "probeMotionGrid") else {
        throw WarpEngine.Error.pipeline("probeMotionGrid missing")
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    // Half-pixel units: at every block center, flow equals that pixel position.
    let field: [SIMD2<Int32>] = (0..<12).map { (i: Int) -> SIMD2<Int32> in
        let x = Int32(7 + 16 * (i % 4))
        let y = Int32(7 + 16 * (i / 4))
        return SIMD2<Int32>(x, y)
    }
    let points: [SIMD2<Float>] = [SIMD2(3.5,3.5), SIMD2(11.5,11.5), SIMD2(19.5,19.5), SIMD2(7.5,7.5), SIMD2(0,0), SIMD2(31,23)]
    let expected: [SIMD2<Float>] = [points[0], points[1], points[2], points[3], SIMD2(3.5,3.5), SIMD2(27.5,19.5)]
    guard let input = device.makeBuffer(bytes: field, length: field.count*MemoryLayout<SIMD2<Int32>>.stride),
          let positions = device.makeBuffer(bytes: points, length: points.count*MemoryLayout<SIMD2<Float>>.stride),
          let output = device.makeBuffer(length: points.count*MemoryLayout<SIMD2<Float>>.stride),
          let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
        throw WarpEngine.Error.pipeline("grid check allocation failed")
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setBuffer(positions, offset: 0, index: 1)
    encoder.setBuffer(output, offset: 0, index: 2)
    encoder.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw WarpEngine.Error.pipeline("grid check GPU command failed") }
    let actual = output.contents().bindMemory(to: SIMD2<Float>.self, capacity: points.count)
    var maxError: Float = 0
    for i in points.indices {
        maxError = max(maxError, abs(actual[i].x-expected[i].x), abs(actual[i].y-expected[i].y))
    }
    print("MOTION GRID: maximum registration error \(maxError) px")
    guard maxError < 0.001 else { throw WarpEngine.Error.pipeline("Motion grid is not registered at block centers") }
    let constant = input.contents().bindMemory(to: SIMD2<Int32>.self, capacity: field.count)
    for i in field.indices { constant[i] = SIMD2<Int32>(8,-4) }
    guard let uniformCommand = queue.makeCommandBuffer(), let uniformEncoder = uniformCommand.makeComputeCommandEncoder() else {
        throw WarpEngine.Error.pipeline("uniform grid check allocation failed")
    }
    uniformEncoder.setComputePipelineState(pipeline)
    uniformEncoder.setBuffer(input, offset: 0, index: 0)
    uniformEncoder.setBuffer(positions, offset: 0, index: 1)
    uniformEncoder.setBuffer(output, offset: 0, index: 2)
    uniformEncoder.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    uniformEncoder.endEncoding()
    uniformCommand.commit()
    uniformCommand.waitUntilCompleted()
    guard uniformCommand.status == .completed else { throw WarpEngine.Error.pipeline("uniform grid check GPU command failed") }
    for i in points.indices { precondition(actual[i] == SIMD2<Float>(4,-2), "Uniform motion changed") }
}
