import SwiftUI
import AppKit
import Contracts

extension Notification.Name {
    static let riftOpenURLs = Notification.Name("RiftOpenURLs")
    static let riftOpenVideo = Notification.Name("RiftOpenVideo")
}

@main
struct RiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var state = RiftPlayerState()

    var body: some Scene {
        WindowGroup("Rift") {
            ContentView<RiftPlayerState>(state: state)
                .frame(minWidth: 780, minHeight: 480)
                .onAppear {
                    AppDelegate.bringPlayerWindowToFront()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("File") {
                Button("Open File...") {
                    NotificationCenter.default.post(name: .riftOpenVideo, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Language") {
                Button("English") { AppDelegate.setLanguage("en") }
                Button("Spanish") { AppDelegate.setLanguage("es") }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Rift") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
                    let credits = String(format: NSLocalizedString("Rift Credits", comment: ""), version, build)
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: NSLocalizedString("Rift", comment: ""),
                            .applicationVersion: version,
                            .version: build,
                            .credits: NSAttributedString(
                                string: credits,
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor
                                ]
                            )
                        ]
                    )
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var pendingOpenURLs: [URL] = []
    private static var fallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let lang = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first,
           ["en", "es"].contains(lang) {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Self.bringPlayerWindowToFront()
        Self.createFallbackWindowIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.enqueueOpenURLs(urls)
        Self.bringPlayerWindowToFront()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    static func takePendingOpenURLs() -> [URL] {
        defer { pendingOpenURLs.removeAll() }
        return pendingOpenURLs
    }

    @MainActor
    private static func enqueueOpenURLs(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        NotificationCenter.default.post(name: .riftOpenURLs, object: nil, userInfo: ["urls": urls])
    }

    @MainActor
    static func setLanguage(_ code: String) {
        guard ["en", "es"].contains(code) else { return }
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restart required", comment: "")
        alert.informativeText = NSLocalizedString("The language change will take effect after restarting Rift.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            let url = Bundle.main.bundleURL
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.open(url, configuration: config)
            NSApplication.shared.terminate(nil)
        }
    }

    @MainActor
    static func bringPlayerWindowToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private static func createFallbackWindowIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard NSApp.windows.isEmpty, fallbackWindow == nil else { return }

            if let existingWindow = NSApp.windows.first(where: { $0.contentViewController?.view is RiftPreviewView }) {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let rootView = RiftPreviewView()
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("Rift", comment: "")
            window.contentViewController = hostingController
            window.center()
            window.makeKeyAndOrderFront(nil)
            fallbackWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}