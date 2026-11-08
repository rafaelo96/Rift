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
    @StateObject private var windowFocus = PlayerWindowFocus()

    var body: some Scene {
        Window("Rift", id: "player") {
            ContentView<RiftPlayerState>(state: state)
                .frame(minWidth: 780, minHeight: 480)
                .onAppear {
                    AppDelegate.bringPlayerWindowToFront()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            RiftCommands(state: state, focus: windowFocus)
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
        Settings {
            RiftSettingsView(state: state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var pendingOpenURLs: [URL] = []
    private static var playerAcceptsOpenURLs = false
    static weak var playerState: RiftPlayerState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Self.bringPlayerWindowToFront()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.enqueueOpenURLs(urls)
        Self.bringPlayerWindowToFront()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.playerState?.saveSessionBeforeTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    static func takePendingOpenURLs() -> [URL] {
        playerAcceptsOpenURLs = true
        openBatchFlush?.cancel()
        defer { pendingOpenURLs.removeAll() }
        return sortedLikeFinder(pendingOpenURLs)
    }

    /// Finder puede entregar una selección múltiple en varias llamadas seguidas
    /// y sin orden garantizado: se juntan durante un instante y se ordenan por
    /// nombre para que formen una sola lista de reproducción.
    @MainActor
    private static func enqueueOpenURLs(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        guard playerAcceptsOpenURLs else { return }
        openBatchFlush?.cancel()
        openBatchFlush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let batch = sortedLikeFinder(pendingOpenURLs)
            pendingOpenURLs.removeAll()
            guard !batch.isEmpty else { return }
            NotificationCenter.default.post(name: .riftOpenURLs, object: nil, userInfo: ["urls": batch])
        }
    }

    private static var openBatchFlush: Task<Void, Never>?

    static func sortedLikeFinder(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Videos recientes en el menú del Dock.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let recent = Self.playerState?.recentVideos, !recent.isEmpty else { return nil }
        let menu = NSMenu()
        for video in recent.prefix(8) {
            let item = NSMenuItem(title: video.title, action: #selector(openRecentFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = video.url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openRecentFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Self.enqueueOpenURLs([url])
        Self.bringPlayerWindowToFront()
    }

    static func isPlayerWindow(_ window: NSWindow?) -> Bool {
        guard let window, !(window is NSPanel) else { return false }
        return window.title == "Rift" || window === playerState?.pictureInPicturePlayerWindow
    }

    @MainActor
    static func bringPlayerWindowToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let window = playerState?.pictureInPicturePlayerWindow
                ?? NSApp.windows.first(where: { $0.title == "Rift" && !($0 is NSPanel) }) {
                configureTranslucentAppearance(for: window)
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private static func configureTranslucentAppearance(for window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }

}
