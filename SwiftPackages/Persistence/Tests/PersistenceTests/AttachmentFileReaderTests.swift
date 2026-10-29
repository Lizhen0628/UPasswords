import Foundation
import Testing

import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("Bounded attachment selection")
struct AttachmentFileReaderTests {
    @Test("Empty and exact-limit files retain all original bytes",
          arguments: [0, AttachmentPolicy.maximumOriginalBytes])
    func readsValidFile(size: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UPWFileReader-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 73, count: size)
        try bytes.write(to: url)
        #expect(try AttachmentFileReader.readContents(of: url) == bytes)
    }

    @Test("A file above the limit is rejected and left untouched")
    func rejectsOversizedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UPWFileReader-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AttachmentPolicy.maximumOriginalBytes + 1))
        try handle.close()
        #expect(throws: AttachmentFileReader.ReadError.tooLarge) {
            try AttachmentFileReader.readContents(of: url)
        }
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == AttachmentPolicy.maximumOriginalBytes + 1)
    }

    @Test("Read failures do not produce an empty successful attachment")
    func rejectsMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UPWMissingFile-\(UUID())")
        #expect(throws: (any Error).self) { try AttachmentFileReader.readContents(of: url) }
    }
}
