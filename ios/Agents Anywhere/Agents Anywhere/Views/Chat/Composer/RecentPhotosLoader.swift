import Foundation
import Observation
import Photos
import UIKit

/// One recent photo in the add-to-chat strip.
struct RecentPhoto: Identifiable, Equatable {
    let id: String
    let thumbnail: UIImage
    let asset: PHAsset

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
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Thumbnail requests are synchronous by design; run them off the main
        // thread so opening the sheet never blocks the composer.
        let photos = await Task.detached(priority: .userInitiated) {
            Self.thumbnails(for: assets)
        }.value
        items = photos
    }

    private nonisolated static func thumbnails(for assets: [PHAsset]) -> [RecentPhoto] {
        let manager = PHImageManager.default()
        let target = CGSize(width: 240, height: 240)
        var found: [RecentPhoto] = []
        found.reserveCapacity(assets.count)
        for asset in assets {
            let request = PHImageRequestOptions()
            request.isSynchronous = true
            request.deliveryMode = .highQualityFormat
            request.resizeMode = .exact
            var thumbnail: UIImage?
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: request) { image, _ in
                thumbnail = image
            }
            if let thumbnail {
                found.append(RecentPhoto(id: asset.localIdentifier, thumbnail: thumbnail, asset: asset))
            }
        }
        return found
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
