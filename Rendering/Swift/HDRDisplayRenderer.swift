import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import QuartzCore
import AppKit
import os

// MARK: - HDRDisplayRenderer (SDR/HDR, sin tone-mapping propio)

public struct VisualAdjustments: Equatable, Sendable {
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float
    /// −1 (fría) … +1 (cálida); 0 deja el balance de blancos intacto.
    public var temperature: Float
    /// Realza los colores apagados y protege la piel y los ya saturados (CIVibrance).
    public var vibrance: Float

    public static let neutral = VisualAdjustments(
        brightness: 0,
        contrast: 1,
        saturation: 1,
        temperature: 0,
        vibrance: 0
    )

    public init(brightness: Float, contrast: Float, saturation: Float, temperature: Float = 0, vibrance: Float = 0) {
        self.brightness = min(max(brightness, -1), 1)
        self.contrast = min(max(contrast, 0), 2)
        self.saturation = min(max(saturation, 0), 2)
        self.temperature = min(max(temperature, -1), 1)
        self.vibrance = min(max(vibrance, -1), 1)
    }

    /// Blanco de destino para CITemperatureAndTint, con la fuente en D65 (6500 K).
    /// Un destino más bajo calienta la imagen. Medido sobre gris 0.5: 4500 K y
    /// 10000 K dan un desplazamiento de color parecido, de ahí la escala asimétrica.
    var targetKelvin: Float {
        temperature >= 0 ? 6500 - 2000 * temperature : 6500 - 3500 * temperature
    }

    /// Contraste como curva en S con el gris medio fijo: negro y blanco no se cortan.
    var contrastCurvePoints: [CIVector] {
        let k = CGFloat(0.25 * (contrast - 1))
        return [CIVector(x: 0, y: 0), CIVector(x: 0.25, y: 0.25 - k), CIVector(x: 0.5, y: 0.5),
                CIVector(x: 0.75, y: 0.75 + k), CIVector(x: 1, y: 1)]
    }

    /// Brillo como gamma de medios tonos (+0.12 → potencia 0.85): negro y blanco quedan fijos.
    var gammaPower: Float { powf(2, -2 * brightness) }
}

public final class HDRDisplayRenderer {
    public let displayLayer: AVSampleBufferDisplayLayer
    public let synchronizer: AVSampleBufferRenderSynchronizer
    @MainActor public var pictureInPictureSubtitle: ((Double) -> String?)?
    @MainActor private var subtitleCompositor: SubtitleCompositor?
    @MainActor private var superResolutionProcessor: SuperResolutionProcessor?
    @MainActor public private(set) var superResolutionMode: SuperResolutionMode = .off
    @MainActor private var lastSourceFrame: (buffer: CVPixelBuffer, duration: CMTime)?
    @MainActor public private(set) var subtitleCompositionFailures = 0
    @MainActor public private(set) var heldFrameRefreshes = 0
    @MainActor private var superResolutionDiagnosticCount = 0
    @MainActor private var superResolutionCaptureCompleted = false

    /// Refresh the held frame as well, so entering/exiting PiP while paused
    /// does not leave a missing or permanently burned-in caption.
    @MainActor
    public func refreshSubtitlePresentation() {
        guard let frame = lastSourceFrame,
              let sample = sampleBuffer(from: frame.buffer, pts: synchronizer.currentTime(), duration: frame.duration) else { return }
        displayLayer.flush()
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        displayLayer.enqueue(sample)
        heldFrameRefreshes += 1
        if pictureInPictureSubtitle == nil { subtitleCompositor = nil }
    }

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

    @MainActor
    public func setSuperResolutionMode(_ mode: SuperResolutionMode) {
        guard superResolutionMode != mode else { return }
        superResolutionMode = mode
        superResolutionDiagnosticCount = 0
        if mode == .off { superResolutionProcessor = nil }
        // A paused synchronizer produces no new samples. Rebuild the held frame
        // now so changing the Visual selector has an immediate visible effect.
        refreshSubtitlePresentation()
    }

    /// Aplica ajustes no destructivos en la capa de presentación. El pipeline
    /// conserva sus CVPixelBuffer originales y la metadata HDR; valores neutros
    /// retiran el filtro por completo para mantener el camino de render original.
    @MainActor
    public func applyVisualAdjustments(_ adjustments: VisualAdjustments, enabled: Bool) {
        guard enabled, adjustments != .neutral else {
            displayLayer.filters = []
            return
        }

        // La capa trabaja en luz lineal. CIColorControls aplica brillo y contraste ahí
        // (contraste 1.1 mandaba a negro todo lo que estaba por debajo del 20 % de gris;
        // brillo +0.06 subía el negro a 82/255), así que solo se usa para la saturación.
        // CIToneCurve y CIGammaAdjust ya operan en gamma sRGB por su cuenta.
        var filters: [CIFilter] = []
        if adjustments.contrast != 1, let curve = CIFilter(name: "CIToneCurve") {
            curve.name = "rift.visual.contrast"
            for (index, point) in adjustments.contrastCurvePoints.enumerated() {
                curve.setValue(point, forKey: "inputPoint\(index)")
            }
            filters.append(curve)
        }
        if adjustments.brightness != 0, let gamma = CIFilter(name: "CIGammaAdjust") {
            gamma.name = "rift.visual.brightness"
            gamma.setValue(adjustments.gammaPower, forKey: "inputPower")
            filters.append(gamma)
        }
        if adjustments.saturation != 1, let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.name = "rift.visual.saturation"
            colorControls.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
            filters.append(colorControls)
        }
        if adjustments.vibrance != 0, let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.name = "rift.visual.vibrance"
            vibrance.setValue(adjustments.vibrance, forKey: "inputAmount")
            filters.append(vibrance)
        }
        if adjustments.temperature != 0, let temperature = CIFilter(name: "CITemperatureAndTint") {
            temperature.name = "rift.visual.temperature"
            temperature.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature.setValue(CIVector(x: CGFloat(adjustments.targetKelvin), y: 0), forKey: "inputTargetNeutral")
            filters.append(temperature)
        }
        displayLayer.filters = filters
    }

    // Wrapping CVPixelBuffer -> CMSampleBuffer con timing, preservando HDR attachments
    // El CVPixelBuffer ya trae kCVImageBuffer* attachments (Decode/Warp los propagó)
    // CMVideoFormatDescriptionCreateForImageBuffer lee esos attachments para el CMSampleBuffer.
    @MainActor
    public func sampleBuffer(from sourceBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        lastSourceFrame = (sourceBuffer, duration)
        var pixelBuffer = sourceBuffer
        if superResolutionMode != .off {
            if superResolutionProcessor == nil { superResolutionProcessor = SuperResolutionProcessor() }
            if let enhanced = superResolutionProcessor?.process(sourceBuffer, mode: superResolutionMode) {
                pixelBuffer = enhanced
            }
            noteSuperResolution(source: sourceBuffer, processed: pixelBuffer, pts: pts)
        }
        return wrap(pixelBuffer, pts: pts, duration: duration)
    }

    /// Igual que `sampleBuffer(from:pts:duration:)`, pero la superresolución espera a
    /// la GPU sin bloquear el hilo principal (la reproducción la llama hasta 60 veces
    /// por segundo). Quien llama debe comprobar tras el `await` que el frame sigue
    /// siendo vigente (seek, cambio de video).
    @MainActor
    public func sampleBufferAsync(from sourceBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) async -> CMSampleBuffer? {
        lastSourceFrame = (sourceBuffer, duration)
        var pixelBuffer = sourceBuffer
        if superResolutionMode != .off {
            if superResolutionProcessor == nil { superResolutionProcessor = SuperResolutionProcessor() }
            if let processor = superResolutionProcessor,
               let enhanced = await processor.processAsync(sourceBuffer, mode: superResolutionMode),
               superResolutionMode != .off {
                pixelBuffer = enhanced
            }
            noteSuperResolution(source: sourceBuffer, processed: pixelBuffer, pts: pts)
        }
        return wrap(pixelBuffer, pts: pts, duration: duration)
    }

    @MainActor
    private func noteSuperResolution(source sourceBuffer: CVPixelBuffer, processed pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if detailedDiagnostics, superResolutionDiagnosticCount < 5 {
            superResolutionDiagnosticCount += 1
            let line = "SUPERRES mode=\(superResolutionMode.rawValue) input=\(CVPixelBufferGetWidth(sourceBuffer))x\(CVPixelBufferGetHeight(sourceBuffer)) format=\(CVPixelBufferGetPixelFormatType(sourceBuffer)) output=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) processed=\(pixelBuffer !== sourceBuffer) bypass=\(superResolutionProcessor?.isAdaptivelyBypassed ?? false)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        captureSuperResolutionComparisonIfRequested(
            source: sourceBuffer,
            processed: pixelBuffer,
            pts: pts.seconds
        )
    }

    /// Subtítulos de PiP y empaquetado CVPixelBuffer → CMSampleBuffer.
    @MainActor
    private func wrap(_ processed: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var pixelBuffer = processed
        if let text = pictureInPictureSubtitle?(pts.seconds), !text.isEmpty {
            if subtitleCompositor == nil { subtitleCompositor = SubtitleCompositor() }
            // A transient compositor allocation failure must not drop the video
            // frame. The larger bounded pool normally avoids this path; keeping
            // the source frame is the safe degradation if system pressure wins.
            if let composed = subtitleCompositor?.composite(pixelBuffer, text: text) {
                pixelBuffer = composed
            } else {
                subtitleCompositionFailures += 1
            }
        } else {
            subtitleCompositor?.releaseExcessBuffers()
        }
        var fmt: CMFormatDescription?
        let s1 = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
        guard s1 == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let s2 = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard s2 == noErr else { return nil }
        return sbuf
    }

    /// Opt-in quality harness. Captures the same decoded frame before and after
    /// super resolution, so visual acceptance is based on real content rather
    /// than a synthetic pattern. Inert during normal playback.
    @MainActor
    private func captureSuperResolutionComparisonIfRequested(
        source: CVPixelBuffer,
        processed: CVPixelBuffer,
        pts: Double
    ) {
        guard !superResolutionCaptureCompleted,
              processed !== source,
              let directory = ProcessInfo.processInfo.environment["RIFT_SUPERRES_CAPTURE_DIR"],
              !directory.isEmpty else { return }
        let targetPTS = ProcessInfo.processInfo.environment["RIFT_SUPERRES_CAPTURE_AT"].flatMap(Double.init) ?? 0
        guard pts.isFinite, pts >= targetPTS else { return }
        superResolutionCaptureCompleted = true

        let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        do {
            try context.writePNGRepresentation(
                of: CIImage(cvPixelBuffer: source),
                to: outputDirectory.appendingPathComponent("frame-off.png"),
                format: .RGBA8,
                colorSpace: colorSpace
            )
            try context.writePNGRepresentation(
                of: CIImage(cvPixelBuffer: processed),
                to: outputDirectory.appendingPathComponent("frame-visual-strong.png"),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } catch {
            if detailedDiagnostics {
                let line = "SUPERRES capture failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    // Tags de diagnóstico — el caller los setea ANTES de llamar sampleBuffer().
    // Solo lectura en enqueue(); no afectan lógica.
    public var pendingOrigin: String = "unknown"
    public var pendingType: String = "unknown"
    public var pendingSchedulerMode: String = "unknown"

    /// True means admitted to AVKit, not physically presented on screen.
    /// The caller retains the sample and may retry under its bounded deadline.
    @discardableResult
    public func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        enqueueAttempts += 1
        guard displayLayer.status != .failed else {
            lastLayerError = displayLayer.error
            return false
        }
        guard displayLayer.isReadyForMoreMediaData else {
            notReadyEnqueues += 1
            return false
        }
        displayLayer.enqueue(sampleBuffer)
        enqueuedFrames += 1
        if detailedDiagnostics, cadenceLogCount < 300 {
            var timingInfo = CMSampleTimingInfo()
            if CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo) == noErr {
                let ptsSec = CMTimeGetSeconds(timingInfo.presentationTimeStamp)
                let durSec = CMTimeGetSeconds(timingInfo.duration)
                let line = String(format: "[RIFT-CADENCE] #%d origin=%@ type=%@ pts=%.6f dur=%.6f mode=%@\n",
                                  enqueuedFrames, pendingOrigin, pendingType, ptsSec, durSec, pendingSchedulerMode)
                cadenceLogCount += 1
                os_log("%{public}@", log: cadenceLog, type: .debug, line)
            }
        }
        return true
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
        return "attempts=\(enqueueAttempts) admitted=\(enqueuedFrames) notReady=\(notReadyEnqueues) status=\(st) error=\(lastLayerError?.localizedDescription ?? "-")"
    }

    public func resetDiagnostics() {
        enqueuedFrames = 0
        enqueueAttempts = 0
        notReadyEnqueues = 0
        lastLayerError = nil
        cadenceLogCount = 0
    }

    public private(set) var enqueuedFrames = 0
    public private(set) var enqueueAttempts = 0
    public private(set) var notReadyEnqueues = 0
    public private(set) var lastLayerError: Error?
    private var cadenceLogCount = 0
    private let detailedDiagnostics = ProcessInfo.processInfo.environment["RIFT_DIAGNOSTICS"] == "1"
    private let cadenceLog = OSLog(subsystem: "com.rift.player", category: "Cadence")

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
