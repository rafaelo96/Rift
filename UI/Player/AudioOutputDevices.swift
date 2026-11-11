import CoreAudio
import Foundation

/// Salidas de audio de Core Audio (altavoces, auriculares, AirPlay, HDMI).
/// Rift puede usar una distinta de la del sistema o seguir a la del sistema,
/// que es la que macOS cambia solo al conectar una TV AirPlay.
@MainActor
final class AudioOutputDevices: ObservableObject {
    struct Device: Identifiable, Equatable {
        /// `kAudioDevicePropertyDeviceUID`, el valor que espera
        /// `AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID`.
        let id: String
        let name: String
        let isAirPlay: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var systemDefaultName: String?
    /// UID de la salida actual del sistema. "Igual que el sistema" se aplica con
    /// este valor y no con `nil`: en macOS 27.2, asignar `nil` a
    /// `AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID` deja el proceso
    /// sin reconocer el hilo principal como MainActor y SwiftUI se cierra en el
    /// siguiente menú o movimiento del puntero (reproducido 3 de 3 veces).
    @Published private(set) var systemDefaultID: String?

    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    func contains(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return devices.contains { $0.id == uid }
    }

    func refresh() {
        let ids: [AudioObjectID] = Self.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        devices = ids.compactMap { id in
            guard Self.hasOutput(id),
                  let uid: String = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name: String = Self.string(id, kAudioObjectPropertyName) else { return nil }
            let transport: UInt32 = Self.value(id, kAudioDevicePropertyTransportType) ?? 0
            return Device(id: uid, name: name, isAirPlay: transport == kAudioDeviceTransportTypeAirPlay)
        }
        let defaultID: AudioObjectID? = Self.value(AudioObjectID(kAudioObjectSystemObject),
                                                    kAudioHardwarePropertyDefaultOutputDevice)
        systemDefaultName = defaultID.flatMap { Self.string($0, kAudioObjectPropertyName) }
        systemDefaultID = defaultID.flatMap { Self.string($0, kAudioDevicePropertyDeviceUID) }
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr,
              let result else { return nil }
        return result.takeRetainedValue() as String
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// Un dispositivo es de salida si tiene al menos un canal en el ámbito de salida.
    private static func hasOutput(_ object: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, list) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }
}
