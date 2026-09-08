import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import AppKit

// MARK: - HDRDisplayRenderer (SDR/HDR, sin tone-mapping propio)

public final class HDRDisplayRenderer {
    public let displayLayer: AVSampleBufferDisplayLayer
    public let synchronizer: AVSampleBufferRenderSynchronizer

    public init(synchronizer: AVSampleBufferRenderSynchronizer? = nil) {
        let layer = AVSampleBufferDisplayLayer()
        // Permite compartir el synchronizer con otros renderers (p.ej. el audio):
        // video y audio deben vivir en el MISMO reloj para reproducirse en sync.
        let sync = synchronizer ?? AVSampleBufferRenderSynchronizer()
        // EDR: necesario para que PQ/BT.2020 no se aplaste a SDR
        layer.wantsExtendedDynamicRangeContent = true
        // El headroom lo elige el sistema según la pantalla EDR; no forzar aquí.
        // En macOS 11+, el EDR se activa automáticamente si la pantalla lo soporta
        // y el contenido lleva attachments PQ/BT.2020 correctos.
        // La capa debe estar en modo que respete attachments, no tone-map propio
        layer.videoGravity = .resizeAspect

        sync.addRenderer(layer)
        self.displayLayer = layer
        self.synchronizer = sync
    }

    public func attach(to viewLayer: CALayer) {
        viewLayer.addSublayer(displayLayer)
        displayLayer.frame = viewLayer.bounds
        displayLayer.needsDisplayOnBoundsChange = true
    }

    // Wrapping CVPixelBuffer -> CMSampleBuffer con timing, preservando HDR attachments
    // El CVPixelBuffer ya trae kCVImageBuffer* attachments (Decode/Warp los propagó)
    // CMVideoFormatDescriptionCreateForImageBuffer lee esos attachments para el CMSampleBuffer.
    public func sampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var fmt: CMFormatDescription?
        let s1 = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
        guard s1 == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let s2 = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard s2 == noErr else { return nil }
        return sbuf
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Apple espera requestMediaDataWhenReady, pero para probe simple usamos isReady
        // En producción: displayLayer.requestMediaDataWhenReady(on: queue) { while isReady { enqueue } }
        enqueuedFrames += 1
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            notReadyEnqueues += 1
            if displayLayer.status == .failed, let err = displayLayer.error {
                if lastLayerError?.localizedDescription != err.localizedDescription {
                    lastLayerError = err
                }
            }
            displayLayer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self] in
                guard let self else { return }
                while self.displayLayer.isReadyForMoreMediaData {
                    // caller should have queued via sampleBuffer(from:)
                    break
                }
            }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    /// Diags de presentación vs encolado. `notReadyEnqueues > 0` sostenido
    /// indica que la capa NO está drenando a su ritmo: los buffers encolados
    /// en esa condición están en riesgo de descarte silencioso (el contador
    /// FPS del UI cuenta encolados, no presentados → puede leer 60 y mostrar 24).
    public func enqueueDiagnostics() -> String {
        let st: String
        if displayLayer.status == .failed {
            st = "failed(\(lastLayerError?.localizedDescription ?? "?"))"
        } else {
            st = "\(displayLayer.status.rawValue)"
        }
        return "enqueued=\(enqueuedFrames) notReady=\(notReadyEnqueues) status=\(st) error=\(lastLayerError?.localizedDescription ?? "-")"
    }

    public func resetDiagnostics() {
        enqueuedFrames = 0
        notReadyEnqueues = 0
        lastLayerError = nil
    }

    public private(set) var enqueuedFrames = 0
    public private(set) var notReadyEnqueues = 0
    public private(set) var lastLayerError: Error?

    public func flush() {
        displayLayer.flush()
        displayLayer.flushAndRemoveImage()
    }

    // Verificación visual HDR: en pantalla EDR, el contenido PQ debe mostrar highlights > SDR
    public static func isHDRDisplayAvailable() -> Bool {
        guard let screen = NSScreen.main else { return false }
        if #available(macOS 11.0, *) {
            return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        }
        return false
    }
}
