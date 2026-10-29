import Foundation

/// Shared limits for newly added, replaced, or imported attachment content.
public enum AttachmentPolicy {
    /// Maximum original file size; existing oversized attachments remain readable and exportable.
    public static let maximumOriginalBytes = 20 * 1024 * 1024
}
