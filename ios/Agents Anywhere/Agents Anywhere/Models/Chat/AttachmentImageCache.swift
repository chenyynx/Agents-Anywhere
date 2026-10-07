import CryptoKit
import Foundation

/// Disk-backed LRU cache for full-resolution attachment image bytes.
///
/// The tap-to-open path used to re-download the whole original through the
/// base64 JSON envelope on every open. This cache lets a second open serve the
/// original straight off disk with zero network, and lets the first open keep
/// the bytes so a re-open (or a scroll away and back) never re-fetches.
///
/// Identity is member-scoped by content, not by surface: the wire attachment
/// already carries a `sha256`, so the same bytes reached from the bubble, the
/// viewer, or a re-loaded timeline share one file. It falls back to the file
/// id only when the payload has no digest (older servers, optimistic bubbles).
///
/// Eviction is least-recently-used under a byte ceiling. Ordering is durable:
/// files touched this launch rank above files that were only discovered on
/// disk (a cold start), and within each group older accesses are evicted first.
@MainActor
final class AttachmentImageCache {
    /// Content identity for one cached original.
    struct Key: Hashable {
        enum Source: String { case sha256, fileId }
        let source: Source
        /// The raw identifier the key was derived from (a hex digest or a file id).
        let value: String
        /// Filesystem-safe name for `value`; also the on-disk file name stem.
        let digest: String
    }

    /// Nonisolated so it can be a default argument value (evaluated outside the
    /// actor) and read from tests.
    nonisolated static let defaultByteLimit = 512 * 1024 * 1024

    let directory: URL
    let byteLimit: Int
    /// Digest -> monotonic access counter for entries touched this launch.
    private var access: [String: Int] = [:]
    private var counter = 0

    /// `directory` defaults to `Caches/aa-attachment-images/`, which iOS may
    /// reclaim under storage pressure — exactly the intended lifetime for a
    /// re-derivable cache.
    init(directory: URL? = nil, byteLimit: Int = AttachmentImageCache.defaultByteLimit) {
        self.byteLimit = max(0, byteLimit)
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aa-attachment-images", isDirectory: true)
    }

    // MARK: - Keys

    /// sha256 first, file id as the fallback. Returns nil when the payload
    /// carries neither, so a caller never writes an unaddressable file.
    func key(for file: V2AttachmentContent) -> Key? {
        if let sha = file.sha256, !sha.isEmpty {
            return Key(source: .sha256, value: sha, digest: Self.digest(sha))
        }
        guard let id = file.fileId, !id.isEmpty else { return nil }
        return Key(source: .fileId, value: id, digest: Self.digest(id))
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The original file extension when the payload names one, so a shared or
    /// exported cache file keeps a usable type. Purely cosmetic; decoding
    /// sniffs content and never relies on it.
    nonisolated static func fileExtension(for file: V2AttachmentContent) -> String? {
        if let name = file.name, !name.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            if isValidExtension(ext) { return ext }
        }
        if let type = file.mediaType?.lowercased(), let slash = type.firstIndex(of: "/") {
            let subtype = String(type[type.index(after: slash)...])
            if subtype == "jpeg" { return "jpg" }
            if subtype == "svg+xml" { return "svg" }
            if isValidExtension(subtype) { return subtype }
        }
        return nil
    }

    private nonisolated static func isValidExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 8 && value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: - Reads

    func contains(_ key: Key) -> Bool { fileURL(for: key) != nil }

    /// Returns the cached file URL for a start-of-download-free decode. Reading
    /// counts as a use, so the LRU keeps the images the user actually opens.
    func url(for key: Key) -> URL? {
        guard let url = fileURL(for: key) else { return nil }
        touch(key)
        return url
    }

    func data(for key: Key) -> Data? {
        guard let url = fileURL(for: key) else { return nil }
        touch(key)
        return try? Data(contentsOf: url)
    }

    func touch(_ key: Key) {
        counter += 1
        access[key.digest] = counter
    }

    // MARK: - Writes

    @discardableResult
    func store(_ data: Data, for key: Key, fileExtension: String? = nil) -> URL? {
        guard let destination = prepare(key, fileExtension: fileExtension) else { return nil }
        do {
            try data.write(to: destination, options: writeOptions)
        } catch {
            return nil
        }
        didStore(key, at: destination)
        return destination
    }

    /// Moves an already-downloaded transfer file into the cache without
    /// loading it into memory, then evicts down to the byte ceiling.
    @discardableResult
    func store(fileAt source: URL, for key: Key, fileExtension: String? = nil) -> URL? {
        guard let destination = prepare(key, fileExtension: fileExtension) else { return nil }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // Cross-volume moves fail; fall back to a copy rather than dropping the bytes.
            try? FileManager.default.removeItem(at: destination)
            do { try FileManager.default.copyItem(at: source, to: destination) } catch { return nil }
            try? FileManager.default.removeItem(at: source)
        }
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        #endif
        didStore(key, at: destination)
        return destination
    }

    private func didStore(_ key: Key, at url: URL) {
        touch(key)
        trim()
    }

    // MARK: - Lifecycle

    /// Total bytes currently held. Used by tests and diagnostics.
    func totalBytes() -> Int { diskFiles().reduce(0) { $0 + $1.bytes } }

    /// Drops every cached original. Called when the account is invalidated or
    /// signed out, so one member's images can never surface for another.
    func clear() {
        access.removeAll()
        counter = 0
        try? FileManager.default.removeItem(at: directory)
    }

    private func trim() {
        let files = diskFiles()
        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > byteLimit else { return }
        for file in files.sorted(by: colderFirst) {
            guard total > byteLimit else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.bytes
            access.removeValue(forKey: file.stem)
        }
    }

    // MARK: - File plumbing

    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }

    private func prepare(_ key: Key, fileExtension: String?) -> URL? {
        // A full or unavailable disk must not crash the viewer; a failed
        // directory or write simply leaves the caller with the thumbnail.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let name = key.digest + (fileExtension.map { ".\($0)" } ?? "")
        let destination = directory.appendingPathComponent(name)
        // Replacing an entry stored earlier under a different extension.
        if let existing = fileURL(for: key), existing != destination {
            try? FileManager.default.removeItem(at: existing)
        }
        return destination
    }

    /// Finds an entry by its digest stem, tolerating an optional extension.
    private func fileURL(for key: Key) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        guard let match = names.first(where: { $0 == key.digest || $0.hasPrefix(key.digest + ".") }) else { return nil }
        return directory.appendingPathComponent(match)
    }

    private struct DiskFile {
        let url: URL
        let stem: String
        let bytes: Int
        let modified: Date
    }

    private func diskFiles() -> [DiskFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let name = url.lastPathComponent
            return DiskFile(url: url, stem: name.split(separator: ".").first.map(String.init) ?? name,
                bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Coldest first: files untouched this launch, oldest on disk ahead of the
    /// rest, then entries accessed this launch in ascending access order.
    private func colderFirst(_ a: DiskFile, _ b: DiskFile) -> Bool {
        let left = access[a.stem], right = access[b.stem]
        switch (left, right) {
        case let (x?, y?): return x < y
        case (nil, _?): return true
        case (_?, nil): return false
        default: return a.modified < b.modified
        }
    }
}

extension V2AttachmentContent {
    /// Digest the server computed over the original bytes; absent on older
    /// payloads and on optimistic bubbles that have not round-tripped yet.
    var sha256: String? { raw["sha256"]?.stringValue }
}
