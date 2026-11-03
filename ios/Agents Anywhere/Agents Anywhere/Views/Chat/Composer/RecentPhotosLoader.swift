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

/// Reads the newest photos for the add-to-chat strip. Read-only; a limited
/// library simply yields fewer items, and a denied library yields none.
@MainActor @Observable
final class RecentPhotosLoader {
    private(set) var items: [RecentPhoto] = []
    private(set) var status: PHAuthorizationStatus = .notDetermined
    private(set) var isLoading = false

    func load(limit: Int = 12) async {
        var granted = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if granted == .notDetermined {
            granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        status = granted
        guard granted == .authorized || granted == .limited else {
            items = []
            return
        }
        // The strip is stable for the sheet's lifetime; a second appearance
        // reuses the already-resolved assets instead of refetching.
        guard items.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Tiles render immediately with placeholders; each thumbnail decodes
        // off the main thread and fills its tile when ready.
        items = assets.map { RecentPhoto(id: $0.localIdentifier, asset: $0, thumbnail: nil) }
        for item in items {
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    Self.thumbnail(for: item.asset)
                }.value
                self?.apply(image, to: item.id)
            }
        }
    }

    private func apply(_ image: UIImage?, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].thumbnail = image
    }

    private nonisolated static func thumbnail(for asset: PHAsset) -> UIImage? {
        let request = PHImageRequestOptions()
        request.isSynchronous = true
        request.deliveryMode = .highQualityFormat
        request.resizeMode = .exact
        var image: UIImage?
        PHImageManager.default().requestImage(for: asset,
            targetSize: CGSize(width: 240, height: 240),
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
