import Foundation

/// Main-actor facade for the Settings cache page. The store is an actor and
/// owns all database work; this type only sequences the calls.
@MainActor
final class LocalCacheService {
    private let store: V2LocalStore

    init(store: V2LocalStore) {
        self.store = store
    }

    func usage() async -> LocalCacheUsage {
        await store.cacheUsage()
    }

    /// Persists the choice, then enforces it immediately.
    func setLimit(_ limit: LocalCacheLimit) async -> LocalCacheUsage {
        LocalCachePolicy.set(limit)
        return await store.enforceCacheLimit()
    }

    /// Removes cached rows/activity/previews; drafts, queued messages and
    /// pinned sessions stay.
    func clearCache() async -> LocalCacheUsage {
        await store.clearCache()
    }
}
