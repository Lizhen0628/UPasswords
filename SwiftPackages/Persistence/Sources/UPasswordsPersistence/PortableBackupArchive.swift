import Foundation
import UPasswordsCore

/// Reads and writes the portable USTAR representation of a self-contained backup package.
public enum PortableBackupArchive {
    private static let blockSize = 512
    private static let copyBufferSize = 1024 * 1024
    private static let maximumOctalSize: UInt64 = 0o77777777777

    /// Creates a portable archive atomically from a backup package directory.
    ///
    /// - Parameters:
    ///   - directory: A package directory containing only supported backup files.
    ///   - archive: Destination file URL. It must not already exist.
    /// - Throws: Invalid paths, unsupported files, source changes, or filesystem errors.
    public static func createArchive(from directory: URL, to archive: URL) throws {
        let fileManager = FileManager.default
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true,
              archive.isFileURL,
              !fileManager.fileExists(atPath: archive.path) else {
            throw PortableBackupArchiveError.invalidPackage
        }

        let root = directory.standardizedFileURL
        let files = try packageFiles(in: root)
        guard !files.isEmpty else { throw PortableBackupArchiveError.invalidPackage }

        let parent = archive.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".\(archive.lastPathComponent).\(UUID().uuidString).partial")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw PortableBackupArchiveError.fileSystemFailure
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let output = try FileHandle(forWritingTo: temporary)
        var outputClosed = false
        defer {
            if !outputClosed { try? output.close() }
        }

        for file in files {
            let values = try file.url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw PortableBackupArchiveError.fileSystemFailure
            }
            let size = UInt64(fileSize)
            guard size <= maximumOctalSize else {
                throw PortableBackupArchiveError.fileTooLarge
            }
            let header = try makeHeader(path: file.path, size: size)
            try output.write(contentsOf: Data(header))
            try writeFile(file.url, expectedSize: size, to: output)

            let padding = paddingSize(for: size)
            if padding > 0 {
                try output.write(contentsOf: Data(repeating: 0, count: padding))
            }
        }

        try output.write(contentsOf: Data(repeating: 0, count: blockSize * 2))
        try output.synchronize()
        try output.close()
        outputClosed = true
        try fileManager.moveItem(at: temporary, to: archive)
    }

    /// Extracts a portable archive into a new directory, publishing it with one rename.
    ///
    /// - Parameters:
    ///   - archive: USTAR file containing a supported backup package.
    ///   - directory: Destination directory URL. It must not already exist.
    /// - Throws: Invalid headers or paths, unsupported entries, or filesystem errors.
    public static func extractArchive(at archive: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        guard archive.isFileURL,
              !fileManager.fileExists(atPath: directory.path) else {
            throw PortableBackupArchiveError.invalidPackage
        }

        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".\(directory.lastPathComponent).\(UUID().uuidString).partial",
            isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            _ = try scanArchive(at: archive, destination: temporary, requestedPath: nil, maximumReadSize: nil)
            try fileManager.moveItem(at: temporary, to: directory)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    static func filePaths(in archive: URL) throws -> [String: Int64] {
        try scanArchive(at: archive, destination: nil, requestedPath: nil, maximumReadSize: nil).files
    }

    static func readFile(
        at archive: URL,
        path: String,
        maximumSize: Int
    ) throws -> Data {
        guard maximumSize >= 0 else { throw PortableBackupArchiveError.invalidPackage }
        let result = try scanArchive(
            at: archive,
            destination: nil,
            requestedPath: path,
            maximumReadSize: maximumSize)
        guard let data = result.requestedData else {
            throw PortableBackupArchiveError.invalidPackage
        }
        return data
    }

    private static func packageFiles(in root: URL) throws -> [PackageFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants]) else {
            throw PortableBackupArchiveError.fileSystemFailure
        }

        var files: [PackageFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PortableBackupArchiveError.unsupportedEntry
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true,
                  let path = relativePath(of: url, to: root),
                  isSupportedPackagePath(path) else {
                throw PortableBackupArchiveError.unsupportedEntry
            }
            files.append(PackageFile(path: path, url: url))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func scanArchive(
        at archive: URL,
        destination: URL?,
        requestedPath: String?,
        maximumReadSize: Int?
    ) throws -> ArchiveScanResult {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }

        var files: [String: Int64] = [:]
        var requestedData: Data?
        var foundTerminator = false

        while true {
            let header = try readExactly(blockSize, from: input)
            if header.allSatisfy({ $0 == 0 }) {
                let secondBlock = try readExactly(blockSize, from: input)
                guard secondBlock.allSatisfy({ $0 == 0 }) else {
                    throw PortableBackupArchiveError.invalidArchive
                }
                while let trailing = try input.read(upToCount: copyBufferSize), !trailing.isEmpty {
                    guard trailing.allSatisfy({ $0 == 0 }) else {
                        throw PortableBackupArchiveError.invalidArchive
                    }
                }
                foundTerminator = true
                break
            }

            let entry = try parseHeader(header)
            guard isSupportedPackagePath(entry.path), files[entry.path] == nil,
                  entry.size <= UInt64(Int64.max) else {
                throw PortableBackupArchiveError.invalidArchive
            }
            files[entry.path] = Int64(entry.size)

            let shouldRead = entry.path == requestedPath
            if shouldRead,
               let maximumReadSize,
               entry.size > UInt64(maximumReadSize) {
                throw PortableBackupArchiveError.fileTooLarge
            }

            let outputURL: URL?
            if let destination {
                outputURL = try createDestinationFile(entry.path, in: destination)
            } else {
                outputURL = nil
            }
            let output: FileHandle?
            if let outputURL {
                output = try FileHandle(forWritingTo: outputURL)
            } else {
                output = nil
            }
            defer { try? output?.close() }

            if shouldRead { requestedData = Data() }
            var remaining = entry.size
            while remaining > 0 {
                let amount = Int(min(UInt64(copyBufferSize), remaining))
                let chunk = try readExactly(amount, from: input)
                try output?.write(contentsOf: chunk)
                if shouldRead { requestedData?.append(chunk) }
                remaining -= UInt64(amount)
            }

            let padding = paddingSize(for: entry.size)
            if padding > 0 {
                let paddingBytes = try readExactly(padding, from: input)
                guard paddingBytes.allSatisfy({ $0 == 0 }) else {
                    throw PortableBackupArchiveError.invalidArchive
                }
            }
        }

        guard foundTerminator, !files.isEmpty else {
            throw PortableBackupArchiveError.invalidArchive
        }
        return ArchiveScanResult(files: files, requestedData: requestedData)
    }

    private static func createDestinationFile(_ path: String, in root: URL) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        var parent = root
        for component in components.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let name = components.last else { throw PortableBackupArchiveError.invalidArchive }
        let file = parent.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw PortableBackupArchiveError.invalidArchive
        }
        return file
    }

    private static func writeFile(_ source: URL, expectedSize: UInt64, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var remaining = expectedSize
        while remaining > 0 {
            let amount = Int(min(UInt64(copyBufferSize), remaining))
            guard let chunk = try input.read(upToCount: amount), !chunk.isEmpty else {
                throw PortableBackupArchiveError.sourceChanged
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
            throw PortableBackupArchiveError.sourceChanged
        }
    }

    private static func makeHeader(path: String, size: UInt64) throws -> [UInt8] {
        let parts = try splitPath(path)
        var header = [UInt8](repeating: 0, count: blockSize)
        try writeString(parts.name, to: &header, range: 0..<100)
        writeOctal(0o600, to: &header, range: 100..<108)
        writeOctal(0, to: &header, range: 108..<116)
        writeOctal(0, to: &header, range: 116..<124)
        writeOctal(size, to: &header, range: 124..<136)
        writeOctal(0, to: &header, range: 136..<148)
        for index in 148..<156 { header[index] = 32 }
        header[156] = Character("0").asciiValue ?? 48
        try writeString("ustar", to: &header, range: 257..<262)
        header[262] = 0
        try writeString("00", to: &header, range: 263..<265)
        try writeString(parts.prefix, to: &header, range: 345..<500)

        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard checksum <= 0o777777 else { throw PortableBackupArchiveError.invalidPackage }
        let digits = String(format: "%06o", checksum)
        guard let digitBytes = digits.data(using: .ascii), digitBytes.count == 6 else {
            throw PortableBackupArchiveError.invalidPackage
        }
        header.replaceSubrange(148..<154, with: digitBytes)
        header[154] = 0
        header[155] = 32
        return header
    }

    private static func parseHeader(_ header: Data) throws -> ArchiveEntry {
        guard header.count == blockSize,
              header[257..<263].elementsEqual(Array("ustar\0".utf8)),
              header[263..<265].elementsEqual(Array("00".utf8)),
              header[156] == 0 || header[156] == Character("0").asciiValue else {
            throw PortableBackupArchiveError.invalidArchive
        }

        var checksumHeader = Array(header)
        let declaredChecksum = try parseOctal(header[148..<156])
        for index in 148..<156 { checksumHeader[index] = 32 }
        let actualChecksum = checksumHeader.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard declaredChecksum == actualChecksum else {
            throw PortableBackupArchiveError.invalidArchive
        }

        let name = try readString(header[0..<100])
        let prefix = try readString(header[345..<500])
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        guard isSupportedPackagePath(path) else { throw PortableBackupArchiveError.invalidArchive }
        return ArchiveEntry(path: path, size: try parseOctal(header[124..<136]))
    }

    private static func splitPath(_ path: String) throws -> (name: String, prefix: String) {
        guard isSupportedPackagePath(path) else { throw PortableBackupArchiveError.invalidPackage }
        let bytes = Array(path.utf8)
        if bytes.count <= 100 { return (path, "") }
        let separators = path.indices.reversed().filter { path[$0] == "/" }
        for separator in separators {
            let prefix = String(path[..<separator])
            let name = String(path[path.index(after: separator)...])
            if prefix.utf8.count <= 155, name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        throw PortableBackupArchiveError.invalidPackage
    }

    private static func relativePath(of file: URL, to root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    private static func isSupportedPackagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }

        if components.count == 1 {
            return ["Info.json", "Manifest.sealed", "Snapshot.upw", "Snapshot.upwkey"].contains(path)
        }
        if components.count == 2, components[0] == "Attachments" {
            let stem = components[1].dropLast(".cipher".count)
            guard components[1].hasSuffix(".cipher"), stem.count == 73 else { return false }
            let separator = stem.index(stem.startIndex, offsetBy: 36)
            return isPortableUUID(String(stem[..<separator]))
                && isPortableUUID(String(stem[stem.index(after: separator)...]))
        }
        if components.count == 3, components[0] == "Conflicts" {
            return isHex(components[1]) && components[1].count == 32
                && components[2].hasSuffix(".cipher")
                && isHex(components[2].dropLast(".cipher".count))
                && components[2].dropLast(".cipher".count).count == 32
        }
        return false
    }

    private static func isHex<S: StringProtocol>(_ value: S) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isPortableUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 5
            && [8, 4, 4, 4, 12].enumerated().allSatisfy { index, length in
                parts[index].count == length && isHex(parts[index])
            }
    }

    private static func writeString(_ value: String, to bytes: inout [UInt8], range: Range<Int>) throws {
        guard value.utf8.count <= range.count,
              value.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
            throw PortableBackupArchiveError.invalidPackage
        }
        bytes.replaceSubrange(range.lowerBound..<(range.lowerBound + value.utf8.count), with: value.utf8)
    }

    private static func writeOctal(_ value: UInt64, to bytes: inout [UInt8], range: Range<Int>) {
        let digits = String(format: "%0*llo", range.count - 1, value)
        bytes.replaceSubrange(range.lowerBound..<(range.upperBound - 1), with: digits.utf8)
        bytes[range.upperBound - 1] = 0
    }

    private static func readString(_ bytes: Data.SubSequence) throws -> String {
        let content = bytes.prefix(while: { $0 != 0 })
        guard content.allSatisfy({ $0 > 0 && $0 < 128 }),
              let value = String(bytes: content, encoding: .ascii) else {
            throw PortableBackupArchiveError.invalidArchive
        }
        return value
    }

    private static func parseOctal(_ bytes: Data.SubSequence) throws -> UInt64 {
        let trimmed = bytes.drop(while: { $0 == 0 || $0 == 32 })
            .reversed()
            .drop(while: { $0 == 0 || $0 == 32 })
            .reversed()
        guard !trimmed.isEmpty else { return 0 }
        var result: UInt64 = 0
        for byte in trimmed {
            guard (48...55).contains(byte) else { throw PortableBackupArchiveError.invalidArchive }
            let (product, overflow1) = result.multipliedReportingOverflow(by: 8)
            let (sum, overflow2) = product.addingReportingOverflow(UInt64(byte - 48))
            guard !overflow1, !overflow2 else { throw PortableBackupArchiveError.invalidArchive }
            result = sum
        }
        return result
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw PortableBackupArchiveError.invalidArchive
            }
            result.append(chunk)
        }
        return result
    }

    private static func paddingSize(for size: UInt64) -> Int {
        let remainder = Int(size % UInt64(blockSize))
        return remainder == 0 ? 0 : blockSize - remainder
    }

    private struct PackageFile {
        let path: String
        let url: URL
    }

    private struct ArchiveEntry {
        let path: String
        let size: UInt64
    }

    private struct ArchiveScanResult {
        let files: [String: Int64]
        let requestedData: Data?
    }
}

/// Errors indicating an invalid or unsupported portable backup archive.
public enum PortableBackupArchiveError: Error, LocalizedError {
    case invalidArchive
    case invalidPackage
    case unsupportedEntry
    case sourceChanged
    case fileTooLarge
    case fileSystemFailure

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            L10n.t("portable_backup_error_invalid_archive")
        case .invalidPackage:
            L10n.t("portable_backup_error_invalid_package")
        case .unsupportedEntry:
            L10n.t("portable_backup_error_unsupported_entry")
        case .sourceChanged:
            L10n.t("portable_backup_error_source_changed")
        case .fileTooLarge:
            L10n.t("portable_backup_error_file_too_large")
        case .fileSystemFailure:
            L10n.t("portable_backup_error_filesystem")
        }
    }
}
