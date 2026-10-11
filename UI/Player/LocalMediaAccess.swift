import Foundation

/// A lease keeps security-scoped access alive for asynchronous readers.
final class LocalMediaAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

/// Bookmarks can resolve a renamed/moved file; old path-only records still work.
final class LocalMediaBookmarks {
    private let defaults: UserDefaults
    private let key = "rift.media.bookmarks.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func access(_ requested: URL) -> LocalMediaAccess {
        var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        var stale = false
        let resolved = bookmarks[requested.path].flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        } ?? requested
        let lease = LocalMediaAccess(url: resolved)
        if let data = try? resolved.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[requested.path] = data
            bookmarks[resolved.path] = data
            defaults.set(bookmarks, forKey: key)
        }
        return lease
    }
}

enum PlaybackOpeningBehavior: String, CaseIterable {
    case ask, resume, restart
}
