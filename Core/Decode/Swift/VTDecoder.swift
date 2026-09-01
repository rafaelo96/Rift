import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import Demux

// MARK: - VTDecoder
//
// VTDecompressionSession-backed HEVC decoder (hardware preferred). Each decoded
// CVPixelBuffer carries the HDR color information exposed by Demux (color_trc /
// color_primaries) as CVBufferAttachments, so downstream rendering knows how to
// interpret the samples.
//
// Decoding is one access unit at a time and synchronous: decodeFrame feeds a
// single CMSampleBuffer and returns the corresponding output buffer. Nothing is
// accumulated and nothing is ever written to disk.

public final class VTDecoder: VideoDecoding {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var config: HEVCConfiguration?
    private var track: TrackInfo?

    /// Written on the VT callback thread, read right after the synchronous
    /// decodeFrame returns. The module decodes one frame at a time from a
    /// single thread, which keeps this race-free as currently used.
    private var pendingBuffer: CVPixelBuffer?
    private var pendingStatus: OSStatus?

    public init() {}

    public func prepare(track: TrackInfo) throws {
        close()

        guard track.kind == .video else {
            throw DecodeError.unsupportedFormat("track \(track.streamIndex) is not video")
        }
        guard !track.codecExtradata.isEmpty else {
            throw DecodeError.unsupportedFormat("video track has no codec extradata (hvcC)")
        }

        let config: HEVCConfiguration
        do {
            config = try HEVCConfiguration.parse(track.codecExtradata)
        } catch let error as HEVCConfigurationError {
            throw DecodeError.malformedHvcC(error.description)
        }
        guard !config.parameterSets.isEmpty else {
            throw DecodeError.missingParameterSets
        }
        self.config = config
        self.track = track

        formatDescription = try makeFormatDescription(config)
        // keep a strong local so `session` out-var and self.session agree
        let session = try makeSession(formatDescription!)
        self.session = session
    }

    public func decodeFrame(_ packet: CompressedPacket) throws -> CVPixelBuffer? {
        guard let session, let track, let formatDescription else {
            throw DecodeError.notPrepared
        }
        guard packet.streamIndex == track.streamIndex else {
            throw DecodeError.wrongStream
        }
        guard !packet.data.isEmpty else { return nil }

        let sampleBuffer = try makeSampleBuffer(from: packet, formatDescription: formatDescription)

        pendingBuffer = nil
        pendingStatus = nil
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else { throw DecodeError.decodeFailed(status) }
        if let pendingStatus {
            throw DecodeError.decodeFailed(pendingStatus)
        }

        let buffer = pendingBuffer
        pendingBuffer = nil
        if let buffer {
            attachColorMetadata(to: buffer)
        }
        return buffer
    }

    public func flush() {
        guard let session else { return }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        pendingBuffer = nil
        pendingStatus = nil
    }

    public func close() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        config = nil
        track = nil
        pendingBuffer = nil
        pendingStatus = nil
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Format description & session

    private func makeFormatDescription(_ config: HEVCConfiguration) throws -> CMFormatDescription {
        let sets = config.parameterSets

        // The parameter sets must stay alive only for the duration of the
        // create call (VideoToolbox copies them).
        let storage: [UnsafeMutablePointer<UInt8>] = sets.map { ps in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: ps.bytes.count)
            p.initialize(from: ps.bytes, count: ps.bytes.count)
            return p
        }
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: sets.count)
        let sizes = UnsafeMutablePointer<Int>.allocate(capacity: sets.count)
        defer {
            pointers.deallocate()
            sizes.deallocate()
            storage.forEach { $0.deallocate() }
        }
        for i in 0..<sets.count {
            pointers[i] = UnsafePointer(storage[i])
            sizes[i] = sets[i].bytes.count
        }

        var fmt: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: pointers,
            parameterSetSizes: UnsafePointer(sizes),
            nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            throw DecodeError.formatDescriptionFailed(status)
        }
        return fmt
    }

    private func makeSession(_ formatDescription: CMFormatDescription) throws -> VTDecompressionSession {
        let track = self.track!

        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]

        let width = max(track.width ?? 0, 16)
        let height = max(track.height ?? 0, 16)
        let destination: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [
                kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey as String: true,
            ],
        ]

        var session: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destination as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw DecodeError.sessionFailed(status)
        }
        return session
    }

    // MARK: - Sample buffer creation

    private func makeSampleBuffer(
        from packet: CompressedPacket,
        formatDescription: CMFormatDescription
    ) throws -> CMSampleBuffer {
        let blockBuffer = try makeBlockBuffer(packet.data)

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: packet.duration, preferredTimescale: 90_000),
            presentationTimeStamp: CMTime(seconds: packet.pts, preferredTimescale: 90_000),
            decodeTimeStamp: CMTime(seconds: packet.dts, preferredTimescale: 90_000)
        )
        var sampleSize = packet.data.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DecodeError.sampleBufferFailed(status)
        }
        return sampleBuffer
    }

    private func makeBlockBuffer(_ data: [UInt8]) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-12740) /* bad param */ }
            // Copy into allocator-owned memory: the block buffer stays valid
            // past this call even if `data` is released.
            let memory = UnsafeMutableRawPointer.allocate(
                byteCount: raw.count,
                alignment: MemoryLayout<UInt8>.alignment
            )
            memory.copyMemory(from: base, byteCount: raw.count)

            var out: CMBlockBuffer?
            let s = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: memory,
                blockLength: raw.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: raw.count,
                flags: 0,
                blockBufferOut: &out
            )
            if s != kCMBlockBufferNoErr {
                memory.deallocate() // block buffer never took ownership
            }
            blockBuffer = out
            return s
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw DecodeError.blockBufferFailed(status)
        }
        return blockBuffer
    }

    // MARK: - HDR color attachments

    /// Copies the track's color metadata (color_trc / color_primaries from
    /// Demux) onto the decoded buffer so downstream renderers can interpret HDR.
    private func attachColorMetadata(to buffer: CVPixelBuffer) {
        guard let track else { return }
        if let transfer = Self.cvTransferFunction(for: track.colorTransfer) {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferTransferFunctionKey,
                transfer as CFTypeRef,
                .shouldPropagate
            )
        }
        if let primaries = Self.cvColorPrimaries(for: track.colorPrimaries) {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferColorPrimariesKey,
                primaries as CFTypeRef,
                .shouldPropagate
            )
        }
        if let matrix = Self.cvYCbCrMatrix(for: track.colorPrimaries) {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferYCbCrMatrixKey,
                matrix as CFTypeRef,
                .shouldPropagate
            )
        }
    }

    private static func cvTransferFunction(for trc: Int?) -> CFString? {
        switch trc {
        case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ  // AVCOL_TRC_SMPTE2084
        case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG // AVCOL_TRC_ARIB_STD_B67
        case 1:  return kCVImageBufferTransferFunction_ITU_R_709_2  // AVCOL_TRC_BT709
        case 13: return kCVImageBufferTransferFunction_sRGB            // AVCOL_TRC_SRGB
        default: return nil
        }
    }

    private static func cvColorPrimaries(for primaries: Int?) -> CFString? {
        switch primaries {
        case 9:  return kCVImageBufferColorPrimaries_ITU_R_2020 // AVCOL_PRI_BT2020
        case 1:  return kCVImageBufferColorPrimaries_ITU_R_709_2  // AVCOL_PRI_BT709
        case 12: return kCVImageBufferColorPrimaries_P3_D65     // AVCOL_PRI_SMPTE432
        default: return nil
        }
    }

    private static func cvYCbCrMatrix(for primaries: Int?) -> CFString? {
        switch primaries {
        case 9:  return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case 1:  return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        default: return nil
        }
    }

    // MARK: - VT output callback

    /// Receives decoded buffers. `outputCallbackRefCon` points at the VTDecoder
    /// (passUnretained — the decoder outlives its session). On macOS 26+ the SDK
    /// marks CVBufferRef as ARC-managed, so the callback hands the buffer to the
    /// decoder via an Unmanaged-managed reference; `decodeFrame` takes ownership.
    private static let outputCallback: VTDecompressionOutputCallback = {
        refCon, _, status, _, imageBuffer, _, _ in
        guard let refCon else { return }
        let decoder = Unmanaged<VTDecoder>.fromOpaque(refCon).takeUnretainedValue()
        guard status == noErr else {
            decoder.pendingStatus = status
            return
        }
        if let imageBuffer {
            // Hand the (already retained) buffer to decodeFrame. CFPixelBuffer
            // is CFTypeRef-backed; bridging via Unmanaged transfers ownership.
            let managed = Unmanaged<CVPixelBuffer>.passRetained(imageBuffer)
            decoder.pendingBuffer = managed.takeRetainedValue()
        }
    }
}