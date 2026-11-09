import Foundation
import CoreVideo
import Interpolation

/// MV_PAIR_HASH=1: interpola pares reales consecutivos con el perfil de Frame+
/// (1/3 y 2/3, con contexto de 4 frames) e imprime un hash de cada frame
/// generado y el coste medio por par. Sirve para comprobar que un cambio de
/// eficiencia deja la salida idéntica byte por byte en el mismo chip.
/// MV_PAIR_HASH_QUALITY=0…2 elige el work plane (por defecto 0, ligero).
func checkPairHashes(buffers: [CVPixelBuffer]) throws {
    guard buffers.count >= 4 else { print("PAIR HASH: need at least 4 frames"); return }
    let w=CVPixelBufferGetWidth(buffers[0]),h=CVPixelBufferGetHeight(buffers[0])
    let quality=Int(ProcessInfo.processInfo.environment["MV_PAIR_HASH_QUALITY"] ?? "0") ?? 0
    let profile: InterpolationConfig = quality == 2 ? .fluidHighQuality : quality == 1 ? .fluid : .fluidEconomy
    let config=profile.fittingAspect(width: w,height: h)
    let engine=try MotionCompensator(config: config)
    func fnv(_ buffer: CVPixelBuffer,into hash: inout UInt64) {
        CVPixelBufferLockBaseAddress(buffer,.readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let rowBytes=CVPixelBufferGetWidthOfPlane(buffer,plane)*(plane==0 ? 1 : 2)*2
            let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
            let base=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer,plane) {
                let row=base.advanced(by: y*stride)
                for x in 0..<rowBytes { hash=(hash^UInt64(row[x]))&*0x100000001b3 }
            }
        }
    }
    var total: UInt64=0xcbf29ce484222325
    var costs=[Double]()
    for i in 1..<(buffers.count-2) {
        let context=InterpolationTemporalContext(before: buffers[i-1],after: buffers[i+2],beforeInterval: 1,afterInterval: 1)
        let start=DispatchTime.now().uptimeNanoseconds
        let result=engine.interpolatePair(I0: buffers[i],I1: buffers[i+1],tValues: [1.0/3,2.0/3],context: context)
        costs.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        var pairHash: UInt64=0xcbf29ce484222325
        for buffer in result.pixelBuffers { fnv(buffer,into: &pairHash) }
        total=(total^pairHash)&*0x100000001b3
        print(String(format: "PAIR %02d frames=%d hash=%016llx ms=%.2f",i,result.pixelBuffers.count,pairHash,costs.last!))
    }
    let steady=costs.dropFirst(3).sorted()
    print(String(format: "PAIR HASH total=%016llx plane=%dx%d pairs=%d median=%.2fms mean=%.2fms",
                 total,config.workWidth,config.workHeight,costs.count,steady[steady.count/2],steady.reduce(0,+)/Double(steady.count)))
}
