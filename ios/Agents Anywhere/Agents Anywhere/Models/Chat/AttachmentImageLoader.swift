import CryptoKit
import Foundation

/// Downloads original attachment bytes to a local file and returns its file URL.
/// The transport (auth, same-origin, redirect policy, streaming to disk) lives
/// behind this seam so the loader can be exercised without a network.
protocol AttachmentImageDownloader {
    func download(url: URL) async throws -> URL
}

enum AttachmentImageDownloadError: LocalizedError, Equatable {
    case missingURL
    case checksumMismatch
    case downloadUnreadable
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return String(localized: "This image has no download URL.")
        case .checksumMismatch:
            return String(localized: "The downloaded image failed its integrity check.")
        case .downloadUnreadable:
            return String(localized: "The downloaded image could not be read.")
        case .cacheUnavailable:
            return String(localized: "The image could not be stored on this device.")
        }
    }
}

/// Orchestrates the fast path for opening an attachment image: a disk-cache hit
/// returns a local URL with zero network, and a miss streams the original,
/// verifies it against the payload's `sha256`, stores it, and returns the URL.
///
/// Several surfaces can ask for the same image at once (a bubble and its
/// viewer, a rapid re-tap, two rows sharing one file). Requests for one cache
/// key share a single download; joining a flight that is cancelled by its last
/// waiter cancels the work itself.
@MainActor
final class AttachmentImageLoader {
    struct Output: Equatable {
        /// Local file URL the caller can hand to a decoder or a share sheet.
        let url: URL
        /// True when the bytes came from the disk cache (no network was used).
        let isCacheHit: Bool
    }

    private final class Flight: @unchecked Sendable {
        var waiters: [UUID: CheckedContinuation<Output, Error>] = [:]
        var terminal: Swift.Result<Output, Error>?
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
    }

    private let cache: AttachmentImageCache
    private let downloader: AttachmentImageDownloader
    private var flights: [AttachmentImageCache.Key: Flight] = [:]

    init(cache: AttachmentImageCache, downloader: AttachmentImageDownloader) {
        self.cache = cache
        self.downloader = downloader
    }

    func open(_ file: V2AttachmentContent) async throws -> Output {
        let key = cache.key(for: file)
        if let key, let cached = cache.url(for: key) {
            return Output(url: cached, isCacheHit: true)
        }
        guard let openUrl = file.openUrl, let url = URL(string: openUrl) else {
            throw AttachmentImageDownloadError.missingURL
        }
        guard let key else { throw AttachmentImageDownloadError.missingURL }

        if let existing = flights[key] { return try await join(existing, key: key) }

        let task = Task { @MainActor in
            // A strong capture keeps the loader (and therefore the flight and
            // its waiters) alive until the download settles; otherwise a
            // dealloc mid-flight would strand every awaiting continuation.
            do {
                let output = try await self.perform(file: file, key: key, url: url)
                self.settle(key: key, with: .success(output))
            } catch {
                self.settle(key: key, with: .failure(error))
            }
        }
        let flight = Flight(task: task)
        flights[key] = flight
        return try await join(flight, key: key)
    }

    // MARK: - Flight coordination

    private func join(_ flight: Flight, key: AttachmentImageCache.Key) async throws -> Output {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let terminal = flight.terminal {
                    continuation.resume(with: terminal)
                } else {
                    flight.waiters[waiter] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiter, key: key) }
        }
    }

    private func cancelWaiter(_ waiter: UUID, key: AttachmentImageCache.Key) {
        guard let flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        // The last waiter to leave takes the work with it: no observer remains,
        // so the transfer is cancelled rather than left to finish unseen.
        if flight.waiters.isEmpty { abandon(flight, key: key) }
    }

    private func settle(key: AttachmentImageCache.Key, with result: Swift.Result<Output, Error>) {
        // Detached (cancelled because no waiters remained): nothing to deliver.
        guard let flight = flights[key] else { return }
        flights[key] = nil
        flight.terminal = result
        let waiters = flight.waiters
        flight.waiters = [:]
        for continuation in waiters.values { continuation.resume(with: result) }
    }

    private func abandon(_ flight: Flight, key: AttachmentImageCache.Key) {
        if flights[key] === flight { flights[key] = nil }
        flight.task.cancel()
    }

    // MARK: - Work

    private func perform(file: V2AttachmentContent, key: AttachmentImageCache.Key, url: URL) async throws -> Output {
        let transfer = try await downloader.download(url: url)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: transfer)
            throw CancellationError()
        }
        guard let digest = Self.sha256(ofFileAt: transfer) else {
            try? FileManager.default.removeItem(at: transfer)
            throw AttachmentImageDownloadError.downloadUnreadable
        }
        // The server's digest is the authority: a mismatch means corruption in
        // transit, so the bytes are dropped and never enter the cache.
        if let expected = file.sha256, !expected.isEmpty, digest.caseInsensitiveCompare(expected) != .orderedSame {
            try? FileManager.default.removeItem(at: transfer)
            throw AttachmentImageDownloadError.checksumMismatch
        }
        guard let stored = cache.store(fileAt: transfer, for: key,
                                       fileExtension: AttachmentImageCache.fileExtension(for: file)) else {
            try? FileManager.default.removeItem(at: transfer)
            throw AttachmentImageDownloadError.cacheUnavailable
        }
        return Output(url: stored, isCacheHit: false)
    }

    /// Streaming SHA-256 so a 25 MiB original is never held in memory whole.
    /// A nil read is end-of-file (not an error); only a thrown read is a failure.
    nonisolated static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20) {
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Production downloader over the shared transport, which already enforces
/// same-origin, injects the bearer token, follows same-origin redirects and
/// streams the body to a temporary file.
struct TransportAttachmentImageDownloader: AttachmentImageDownloader {
    let transport: any HTTPTransport
    func download(url: URL) async throws -> URL { try await transport.download(url) }
}

/// Downloader backed by the attachment service's raw byte route, so a surface
/// that only holds `services.attachments` can build a loader without reaching
/// for the transport.
struct ServiceAttachmentImageDownloader: AttachmentImageDownloader {
    let service: V2AttachmentService
    func download(url: URL) async throws -> URL {
        try await service.downloadFile(openUrl: url.absoluteString)
    }
}

extension AttachmentImageLoader {
    convenience init(cache: AttachmentImageCache, service: V2AttachmentService) {
        self.init(cache: cache, downloader: ServiceAttachmentImageDownloader(service: service))
    }
}
