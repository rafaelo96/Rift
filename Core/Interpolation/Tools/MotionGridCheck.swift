import Foundation
import Metal
import Interpolation

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
