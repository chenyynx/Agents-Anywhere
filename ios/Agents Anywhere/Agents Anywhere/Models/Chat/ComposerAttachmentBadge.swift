import Foundation

/// The type badge on a composer attachment chip: the file extension, uppercased
/// (round30: the official file face shows a badge such as "CONF" above the
/// name). A name without an extension has no badge.
enum ComposerAttachmentBadge {
    static func text(for name: String) -> String? {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? nil : ext
    }
}
