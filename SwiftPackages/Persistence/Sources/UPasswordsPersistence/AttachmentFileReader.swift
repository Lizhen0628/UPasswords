import Foundation

import UPasswordsCore

/// Reads a newly selected attachment without allocating an unbounded file in memory.
public enum AttachmentFileReader {
    /// Selection failures that are independent of platform file access errors.
    public enum ReadError: LocalizedError, Equatable {
        case tooLarge

        public var errorDescription: String? { L10n.t("attach_file_error") }
    }

    private static let chunkBytes = 64 * 1024

    /// Checks the reported size, then bounds actual reads in case the file grows during selection.
    /// - Parameter url: Readable file URL; callers own any security-scoped access.
    /// - Returns: Complete original bytes, including a valid empty file.
    /// - Throws: Size limit, metadata, opening, or reading failures. Partial content is never returned.
    public static func readContents(of url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let maximumBytes = AttachmentPolicy.maximumOriginalBytes
        if let size = values.fileSize, size > maximumBytes { throw ReadError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(max(0, values.fileSize ?? 0), maximumBytes))
        while let chunk = try handle.read(upToCount: min(chunkBytes, maximumBytes - data.count + 1)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        }
        return data
    }
}
