import AppKit
import CoreImage
import CoreText
import CoreVideo

/// Presentation-only composition. Originals are never modified; the output pool
/// has a hard allocation limit even when AVKit retains queued frames.
@MainActor
final class SubtitleCompositor {
    /// AVSampleBufferDisplayLayer can retain several frames ahead of playback,
    /// especially at 60 fps. Keep enough presentation buffers for that queue
    /// while preserving a strict upper bound for 4K/HDR memory use.
    private static let maximumOutstandingFrames = 12

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var dimensions: CGSize = .zero
    private var format: OSType = 0
    private var cachedText: String?
    private var cachedOverlay: CIImage?

    func composite(_ source: CVPixelBuffer, text: String) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        if size != dimensions || pixelFormat != format {
            pool = nil
            cachedText = nil
            cachedOverlay = nil
            dimensions = size
            format = pixelFormat
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        let limit = [
            kCVPixelBufferPoolAllocationThresholdKey as String: Self.maximumOutstandingFrames
        ] as CFDictionary
        var allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nil, pool, limit, &destination)
        if allocationStatus == kCVReturnWouldExceedAllocationThreshold {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
            allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                nil, pool, limit, &destination)
        }
        guard allocationStatus == kCVReturnSuccess, let destination else { return nil }
        if cachedText != text {
            cachedOverlay = makeOverlay(text: text, size: size)
            cachedText = text
        }
        guard let overlay = cachedOverlay else { return nil }
        CVBufferRemoveAllAttachments(destination)
        CVBufferPropagateAttachments(source, destination)
        let image = CIImage(cvPixelBuffer: source)
        // Match the source encoding (including PQ/HLG) on output, rather than
        // attaching HDR tags to pixels that have been converted to SDR.
        context.render(overlay.composited(over: image), to: destination,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: image.colorSpace)
        return destination
    }

    func releaseExcessBuffers() {
        guard let pool else { return }
        CVPixelBufferPoolFlush(pool, .excessBuffers)
    }

    private func makeOverlay(text: String, size: CGSize) -> CIImage? {
        let fontSize = max(18, size.width * 0.035)
        let padding = fontSize * 0.4
        let width = size.width * 0.88
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: String(text.prefix(16_384)), attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil, CGSize(width: width - padding * 2, height: size.height * 0.45), nil)
        let height = min(size.height * 0.5, ceil(measured.height + padding * 2))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: Int(ceil(width)), height: Int(ceil(height)),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.setFillColor(CGColor(gray: 0, alpha: 0.65))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rect = CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(
            translationX: (size.width - width) / 2, y: size.height * 0.07))
    }
}
