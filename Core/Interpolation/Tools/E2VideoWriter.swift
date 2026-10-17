import AVFoundation
import CoreVideo

// Bounded SDR-luma diagnostic clips, never a full-source conversion or a playback prerequisite.
final class E2VideoWriter {
    private let writer: AVAssetWriter,input: AVAssetWriterInput,adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int,height: Int
    private(set) var count=0
    init(path: String,width: Int,height: Int) throws {
        self.width=width;self.height=height
        if FileManager.default.fileExists(atPath: path) {try FileManager.default.removeItem(atPath: path)}
        writer=try AVAssetWriter(outputURL: URL(fileURLWithPath: path),fileType: .mp4)
        input=AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:6_000_000,AVVideoMaxKeyFrameIntervalKey:60]])
        input.expectsMediaDataInRealTime=false
        adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        writer.add(input);guard writer.startWriting() else {throw writer.error!};writer.startSession(atSourceTime: .zero)
    }
    func append(_ pixels: [UInt16]) throws {
        while !input.isReadyForMoreMediaData {guard writer.status == .writing else {throw writer.error ?? NSError(domain:"ClipWriter",code:1)};Thread.sleep(forTimeInterval:0.001)}
        var buffer: CVPixelBuffer?;guard CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)==kCVReturnSuccess,let buffer else {throw NSError(domain:"ClipPool",code:1)}
        CVPixelBufferLockBaseAddress(buffer,[]);let stride=CVPixelBufferGetBytesPerRow(buffer);let data=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
        for y in 0..<height {for x in 0..<width {let gray=UInt8(clamping:Int((Float(pixels[y*width+x])*1.8/4).rounded()));let k=y*stride+x*4;data[k]=gray;data[k+1]=gray;data[k+2]=gray;data[k+3]=255}}
        CVPixelBufferUnlockBaseAddress(buffer,[])
        guard adaptor.append(buffer,withPresentationTime: CMTime(value:Int64(count),timescale:60)) else {throw writer.error ?? NSError(domain:"ClipAppend",code:1)};count+=1
    }
    func finish() throws {
        input.markAsFinished();let semaphore=DispatchSemaphore(value:0);writer.finishWriting {semaphore.signal()};semaphore.wait()
        guard writer.status == .completed else {throw writer.error ?? NSError(domain:"ClipFinish",code:1)}
    }
}
