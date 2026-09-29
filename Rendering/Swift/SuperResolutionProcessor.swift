import CoreVideo
import Metal

public enum SuperResolutionMode: String, CaseIterable, Sendable {
    case off
    case soft
    case balanced
    case strong

    fileprivate var detail: Float {
        switch self {
        case .off: return 0
        case .soft: return 0.10
        case .balanced: return 0.22
        case .strong: return 0.35
        }
    }
}

public final class SuperResolutionProcessor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lumaPipeline: MTLComputePipelineState
    private let chromaPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var outputPool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?
    private let poolCapacity = 12
    private let realtimeBudgetMS = 8.0
    private var consecutiveBudgetMisses = 0
    private var bypassFramesRemaining = 0
    public private(set) var lastProcessingMS: Double = 0
    public private(set) var isAdaptivelyBypassed = false

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: superResolutionShadersMSL, options: nil),
              let luma = library.makeFunction(name: "superResolveLuma"),
              let chroma = library.makeFunction(name: "superResolveChroma"),
              let lumaPipeline = try? device.makeComputePipelineState(function: luma),
              let chromaPipeline = try? device.makeComputePipelineState(function: chroma) else { return nil }
        self.device = device
        self.queue = queue
        self.lumaPipeline = lumaPipeline
        self.chromaPipeline = chromaPipeline
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    public static func outputDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let scale = min(2.0, min(3840.0 / Double(width), 2160.0 / Double(height)))
        guard scale > 1.01 else { return (width, height) }
        return (max(2, Int(Double(width) * scale) & ~1),
                max(2, Int(Double(height) * scale) & ~1))
    }

    public func process(_ input: CVPixelBuffer, mode: SuperResolutionMode) -> CVPixelBuffer? {
        guard mode != .off, CVPixelBufferGetPlaneCount(input) >= 2,
              let cache = textureCache else { return nil }
        if bypassFramesRemaining > 0 {
            bypassFramesRemaining -= 1
            isAdaptivelyBypassed = true
            return nil
        }
        isAdaptivelyBypassed = false
        let srcW = CVPixelBufferGetWidth(input), srcH = CVPixelBufferGetHeight(input)
        let outputSize = Self.outputDimensions(width: srcW, height: srcH)
        let format = CVPixelBufferGetPixelFormatType(input)
        let is10Bit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: is10Bit = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: is10Bit = false
        default: return nil
        }
        ensurePool(width: outputSize.width, height: outputSize.height, format: format)
        guard let output = acquireOutput() else { return nil }

        let lumaFormat: MTLPixelFormat = is10Bit ? .r16Uint : .r8Uint
        let chromaFormat: MTLPixelFormat = is10Bit ? .rg16Uint : .rg8Uint
        let srcLuma = texture(input, plane: 0, format: lumaFormat, width: srcW, height: srcH, cache: cache)
        let dstLuma = texture(output, plane: 0, format: lumaFormat, width: outputSize.width, height: outputSize.height, cache: cache)
        let srcCW = CVPixelBufferGetWidthOfPlane(input, 1), srcCH = CVPixelBufferGetHeightOfPlane(input, 1)
        let dstCW = CVPixelBufferGetWidthOfPlane(output, 1), dstCH = CVPixelBufferGetHeightOfPlane(output, 1)
        let srcChroma = texture(input, plane: 1, format: chromaFormat, width: srcCW, height: srcCH, cache: cache)
        let dstChroma = texture(output, plane: 1, format: chromaFormat, width: dstCW, height: dstCH, cache: cache)
        guard let inY = srcLuma.1, let outY = dstLuma.1,
              let inC = srcChroma.1, let outC = dstChroma.1 else { return nil }

        let started = DispatchTime.now().uptimeNanoseconds
        guard encode(lumaInput: inY, lumaOutput: outY,
                     chromaInput: inC, chromaOutput: outC,
                     detail: mode.detail) else { return nil }
        lastProcessingMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        updateRealtimeSafety(measuredMS: lastProcessingMS)
        propagateAttachments(from: input, to: output)
        withExtendedLifetime((srcLuma, dstLuma, srcChroma, dstChroma)) {}
        return output
    }

    private func encode(lumaInput: MTLTexture, lumaOutput: MTLTexture,
                        chromaInput: MTLTexture, chromaOutput: MTLTexture,
                        detail: Float) -> Bool {
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(lumaPipeline)
        encoder.setTexture(lumaInput, index: 0)
        encoder.setTexture(lumaOutput, index: 1)
        var lumaUniforms = SRUniforms(srcW: UInt32(lumaInput.width), srcH: UInt32(lumaInput.height),
                                      dstW: UInt32(lumaOutput.width), dstH: UInt32(lumaOutput.height),
                                      detail: detail)
        encoder.setBytes(&lumaUniforms, length: MemoryLayout<SRUniforms>.stride, index: 0)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (lumaOutput.width + 15) / 16, height: (lumaOutput.height + 15) / 16, depth: 1),
            threadsPerThreadgroup: threads
        )

        encoder.setComputePipelineState(chromaPipeline)
        encoder.setTexture(chromaInput, index: 0)
        encoder.setTexture(chromaOutput, index: 1)
        var chromaUniforms = SRUniforms(srcW: UInt32(chromaInput.width), srcH: UInt32(chromaInput.height),
                                        dstW: UInt32(chromaOutput.width), dstH: UInt32(chromaOutput.height),
                                        detail: 0)
        encoder.setBytes(&chromaUniforms, length: MemoryLayout<SRUniforms>.stride, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (chromaOutput.width + 15) / 16, height: (chromaOutput.height + 15) / 16, depth: 1),
            threadsPerThreadgroup: threads
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return command.status == .completed
    }

    private func updateRealtimeSafety(measuredMS: Double) {
        if measuredMS > realtimeBudgetMS {
            consecutiveBudgetMisses += 1
            if consecutiveBudgetMisses >= 3 {
                // Re-evaluate periodically instead of pinning behavior to a Mac model.
                // The renderer falls back to the untouched source during this cooldown.
                bypassFramesRemaining = 120
                consecutiveBudgetMisses = 0
            }
        } else {
            consecutiveBudgetMisses = 0
        }
    }

    private func ensurePool(width: Int, height: Int, format: OSType) {
        if let key = poolKey, key.width == width, key.height == height, key.format == format,
           outputPool != nil { return }
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return }
        outputPool = pool
        poolKey = (width, height, format)
        CVMetalTextureCacheFlush(textureCache!, 0)
    }

    private func acquireOutput() -> CVPixelBuffer? {
        guard let outputPool else { return nil }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: poolCapacity] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, outputPool, limits, &output) == kCVReturnSuccess else { return nil }
        return output
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         width: Int, height: Int, cache: CVMetalTextureCache) -> (CVMetalTexture?, MTLTexture?) {
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
            format, width, height, plane, &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return (nil, nil) }
        return (wrapped, texture)
    }

    private func propagateAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) as? [String: Any] {
            for (key, value) in attachments {
                CVBufferSetAttachment(destination, key as CFString, value as CFTypeRef, .shouldPropagate)
            }
        }
    }
}

private struct SRUniforms {
    var srcW: UInt32
    var srcH: UInt32
    var dstW: UInt32
    var dstH: UInt32
    var detail: Float
}
