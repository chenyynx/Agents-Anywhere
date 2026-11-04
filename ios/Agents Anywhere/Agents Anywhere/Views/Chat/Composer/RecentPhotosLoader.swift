import Foundation
import Observation
import Photos
import UIKit

/// One recent photo in the add-to-chat strip. The thumbnail fills in
/// asynchronously; until it does the tile draws a placeholder, matching the
/// official `RecentPhotoThumbnail` (`Color.overlay(Image?)`).
struct RecentPhoto: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    var thumbnail: UIImage?

    static func == (lhs: RecentPhoto, rhs: RecentPhoto) -> Bool { lhs.id == rhs.id }
}

private enum RecentPhotoConstants {
    static let limit = 12
    static let thumbnailPixelSize = 240
}

/// App-lifetime read model for the add-to-chat photo strip.
///
/// The official composer keeps `PhotoLibraryAccess` in the SwiftUI environment
/// at scene scope, caches the resolved assets in `assetsById`, and registers a
/// `PHPhotoLibraryChangeObserver` (`ClaudeComposer.LibraryObserver`) so an open
/// strip picks up a new screenshot as soon as it lands in the library.
///
/// AA mirrors that shape with one instance injected from `AgentsAnywhereApp`:
/// a single newest-first fetch, thumbnails cached across sheet presentations,
/// and a change observer that re-reads the newest assets while access is
/// granted. A sheet reopen therefore shows the same photos immediately instead
/// of fetching again, and a screenshot taken while the sheet is open appears
/// without dismissing it.
@MainActor @Observable
final class RecentPhotosLoader {
    private(set) var items: [RecentPhoto] = []
    private(set) var status: PHAuthorizationStatus = .notDetermined
    private(set) var isLoading = false

    @ObservationIgnored private var limit = RecentPhotoConstants.limit
    @ObservationIgnored private var libraryObserver: LibraryChangeObserver?
    @ObservationIgnored private var cachedThumbnails: [String: UIImage] = [:]
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    /// Warms the strip from the composer when access was already granted.
    /// Deliberately does not ask for permission: the system prompt belongs to
    /// the add-to-chat sheet, not to opening a chat.
    func preload(limit: Int = RecentPhotoConstants.limit) async {
        let granted = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        status = granted
        guard granted == .authorized || granted == .limited else { return }
        await refresh(limit: limit)
    }

    /// Sheet entry point: asks once when needed, then reuses the shared cache.
    func load(limit: Int = RecentPhotoConstants.limit) async {
        var granted = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if granted == .notDetermined {
            granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        status = granted
        guard granted == .authorized || granted == .limited else {
            items = []
            return
        }
        await refresh(limit: limit)
    }

    /// Re-reads the newest assets. The fetch is metadata-only and cheap; the
    /// thumbnails that were already decoded stay in `cachedThumbnails`.
    private func refresh(limit: Int) async {
        self.limit = limit
        guard !isLoading else { return }
        isLoading = items.isEmpty
        defer { isLoading = false }

        startObserving()
        rebuildItems()
    }

    private func rebuildItems() {
        let assets = Self.fetchRecentAssets(limit: limit)
        items = assets.map { asset in
            RecentPhoto(id: asset.localIdentifier,
                        asset: asset,
                        thumbnail: cachedThumbnails[asset.localIdentifier])
        }
        loadMissingThumbnails()
    }

    // MARK: - Library changes

    private func startObserving() {
        guard libraryObserver == nil else { return }
        libraryObserver = LibraryChangeObserver { [weak self] in
            guard let self, !self.isLoading else { return }
            guard self.status == .authorized || self.status == .limited else { return }
            self.rebuildItems()
        }
    }

    // MARK: - Thumbnails

    private func loadMissingThumbnails() {
        for item in items {
            let id = item.id
            guard item.thumbnail == nil,
                  cachedThumbnails[id] == nil,
                  thumbnailTasks[id] == nil else { continue }

            let asset = item.asset
            thumbnailTasks[id] = Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    Self.thumbnail(for: asset)
                }.value
                guard let self else { return }
                self.thumbnailTasks[id] = nil
                guard let image else { return }
                self.cachedThumbnails[id] = image
                self.apply(image, to: id)
            }
        }
    }

    private func apply(_ image: UIImage?, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].thumbnail = image
    }

    private nonisolated static func fetchRecentAssets(limit: Int) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private nonisolated static func thumbnail(for asset: PHAsset) -> UIImage? {
        let request = PHImageRequestOptions()
        request.isSynchronous = true
        request.deliveryMode = .highQualityFormat
        request.resizeMode = .exact
        var image: UIImage?
        PHImageManager.default().requestImage(for: asset,
            targetSize: CGSize(width: RecentPhotoConstants.thumbnailPixelSize, height: RecentPhotoConstants.thumbnailPixelSize),
            contentMode: .aspectFill, options: request) { result, _ in image = result }
        return image
    }

    /// The original bytes for a picked thumbnail. Network access is allowed so
    /// iCloud-only assets still resolve.
    func imageData(for item: RecentPhoto) async -> Data? {
        await withCheckedContinuation { continuation in
            let request = PHImageRequestOptions()
            request.isNetworkAccessAllowed = true
            request.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: item.asset, options: request) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// `PHPhotoLibraryChangeObserver` is an Objective-C protocol, so its callback
/// lives outside the observable model. This mirrors the official split between
/// `PhotoLibraryAccess` and `LibraryObserver`.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onUpdate: @MainActor () -> Void

    init(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.onUpdate()
        }
    }
}
