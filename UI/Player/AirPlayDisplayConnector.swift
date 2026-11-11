import AppKit
import ApplicationServices

/// Abre la lista "Duplicar pantalla" del Centro de control desde Rift, para
/// conectar una TV AirPlay sin pasar por Ajustes del Sistema.
///
/// macOS no ofrece una API pública para iniciar la duplicación por AirPlay, y
/// las internas (`AVOutputContext.sharedSystemScreenContext`) devuelven `nil`
/// a apps sin entitlement de Apple (probado en macOS 27.2). Lo que sí se puede
/// es pulsar los controles del sistema por accesibilidad, con el permiso de
/// Accesibilidad del usuario. Los controles se buscan por identificador, que
/// no depende del idioma.
@MainActor
enum AirPlayDisplayConnector {
    enum Outcome {
        /// Había una sola pantalla AirPlay y se pulsó: macOS la está conectando.
        case connecting(String)
        /// La lista quedó abierta para que el usuario elija.
        case listShown
        /// Falta el permiso de Accesibilidad; macOS ya mostró su aviso.
        case needsPermission
        /// Los controles no están donde se esperaba (otra versión de macOS).
        case unavailable
    }

    private static let controlCenterItem = "com.apple.menuextra.controlcenter"
    private static let mirroringModule = "controlcenter-screen-mirroring"
    private static let deviceList = "screen-mirroring-device-list"

    static func connect() async -> Outcome {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return .needsPermission }
        guard let agent = application("com.apple.MenuBarAgent") ?? application("com.apple.controlcenter"),
              let center = application("com.apple.controlcenter"),
              let item = find(in: agent, identifier: controlCenterItem) else { return .unavailable }

        // Si el Centro de control ya está abierto, pulsarlo lo cerraría.
        if find(in: center, identifier: mirroringModule) == nil, find(in: center, identifier: deviceList) == nil {
            guard press(item) else { return .unavailable }
        }
        if await waitFor(deviceList, in: center, timeout: 0.3) == nil {
            guard let module = await waitFor(mirroringModule, in: center, timeout: 2), press(module) else {
                return .unavailable
            }
        }
        guard let list = await waitFor(deviceList, in: center, timeout: 2) else { return .unavailable }
        // La lista se llena al descubrir dispositivos en la red.
        try? await Task.sleep(for: .milliseconds(1200))
        let devices = children(of: list).filter { (attribute($0, kAXRoleAttribute) as? String) == kAXCheckBoxRole as String }
        if devices.count == 1, let device = devices.first,
           (attribute(device, kAXValueAttribute) as? NSNumber)?.intValue == 0, press(device) {
            let name = attribute(device, kAXDescriptionAttribute) as? String ?? ""
            try? await Task.sleep(for: .milliseconds(400))
            // Cierra el Centro de control solo si sigue abierto: pulsarlo
            // cuando ya se cerró lo abriría otra vez.
            if !(attribute(center, kAXWindowsAttribute) as? [AXUIElement] ?? []).isEmpty { _ = press(item) }
            return .connecting(name)
        }
        return .listShown
    }

    // MARK: - Accesibilidad

    private static func application(_ bundleID: String) -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func find(in element: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        if (attribute(element, kAXIdentifierAttribute) as? String) == identifier { return element }
        guard depth < 12 else { return nil }
        for child in children(of: element) {
            if let match = find(in: child, identifier: identifier, depth: depth + 1) { return match }
        }
        return nil
    }

    private static func waitFor(_ identifier: String, in element: AXUIElement, timeout: Double) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = find(in: element, identifier: identifier) { return match }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }

    private static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}
