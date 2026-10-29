import Foundation
import Testing
import UPasswordsCore
@testable import UPasswordsPersistence

@Suite
struct RowSyncBaselineMergeTests {
    @Test
    func mergesChangesToDifferentPersistentFields() throws {
        let username = Field(name: "Username", value: "before")
        let password = Field(name: "Password", type: .password, value: "before")
        var base = Card(title: "Account")
        base.fields = [username, password]
        var local = base
        local.fields[0].value = "local username"
        var remote = base
        remote.fields[1].value = "remote password"

        let merged = try #require(card(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote))))

        #expect(merged.fields[0].value == "local username")
        #expect(merged.fields[1].value == "remote password")
    }

    @Test
    func rejectsDifferentConcurrentValuesForSameField() {
        let field = Field(name: "Password", type: .password, value: "before")
        var base = Card(title: "Account")
        base.fields = [field]
        var local = base
        local.fields[0].value = "local"
        var remote = base
        remote.fields[0].value = "remote"

        #expect(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote)) == nil)
    }

    @Test
    func rejectsConcurrentWholeNoteChanges() {
        var base = Card(title: "Account")
        base.notes = "before"
        var local = base
        local.notes = "local"
        var remote = base
        remote.notes = "remote"

        #expect(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote)) == nil)
    }

    @Test
    func mergesIndependentAttachmentAdditions() throws {
        let base = Card(title: "Account")
        var local = base
        local.files = [Attachment(name: "local.txt", data: Data("local".utf8))]
        var remote = base
        remote.files = [Attachment(name: "remote.txt", data: Data("remote".utf8))]

        let merged = try #require(card(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote))))

        #expect(merged.files.count == 2)
        #expect(Set(merged.files.map(\.name)) == ["local.txt", "remote.txt"])
    }

    @Test
    func rejectsConcurrentEditsToLegacyFieldsWithoutStableIDs() throws {
        let legacyField = try JSONDecoder().decode(
            Field.self,
            from: Data(#"{"name":"Password","type":"password","value":"before","autofill":"off","history":[]}"#.utf8)
        )
        var base = Card(title: "Account")
        base.fields = [legacyField]
        var local = base
        local.fields[0].value = "local"
        var remote = base
        remote.fields[0].name = "Secret"

        #expect(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote)) == nil)
    }

    @Test
    func mergesIndependentCardMetadata() throws {
        let base = Card(title: "Before")
        var local = base
        local.title = "Local title"
        var remote = base
        remote.favorite = true

        let merged = try #require(card(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote))))

        #expect(merged.title == "Local title")
        #expect(merged.favorite)
    }

    @Test
    func detectsLabelValueChangesDespiteIdentityBasedEquality() throws {
        let base = CardLabel(name: "Work", color: "blue", timeStamp: 100)
        var edited = base
        edited.name = "Projects"
        edited.timeStamp = 200
        var timestampOnly = base
        timestampOnly.timeStamp = 300
        let key = RowSyncKey(raw: Data(repeating: 1, count: 32))
        let encrypted = try RowSyncCipher.encryptBaseline(.label(base), key: key)
        let decoded = try #require(RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: base.id))

        #expect(decoded.matches(.label(timestampOnly)))
        #expect(!decoded.matches(.label(edited)))
    }

    @Test
    func mergesIndependentLabelProperties() throws {
        let base = CardLabel(name: "Work", color: "blue")
        var local = base
        local.name = "Projects"
        var remote = base
        remote.pinToTop = true

        let merged = try #require(label(RowSyncBaseline(item: .label(base)).merging(
            local: .label(local), remote: .label(remote))))

        #expect(merged.name == "Projects")
        #expect(merged.pinToTop)
    }

    @Test
    func mergesProfileFieldsByPersistentID() throws {
        let email = Field(name: "Email", type: .email, value: "before")
        let phone = Field(name: "Phone", type: .phone, value: "before")
        var base = UserProfile()
        base.fields = [email, phone]
        var local = base
        local.fields[0].value = "local email"
        var remote = base
        remote.fields[1].value = "remote phone"

        let merged = try #require(profile(RowSyncBaseline(item: .userProfile(base)).merging(
            local: .userProfile(local), remote: .userProfile(remote))))

        #expect(merged.fields[0].value == "local email")
        #expect(merged.fields[1].value == "remote phone")
    }

    @Test
    func mergesAttachmentRenameWithIndependentContentReplacement() throws {
        let attachmentID = UUID()
        let original = Attachment(id: attachmentID, name: "old.txt", data: Data("old".utf8))
        var base = Card(title: "Account")
        base.files = [original]
        var local = base
        local.files[0].name = "renamed.txt"
        var remote = base
        remote.files[0].data = Data("new".utf8)

        let merged = try #require(card(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote))))

        #expect(merged.files[0].name == "renamed.txt")
        #expect(merged.files[0].data == Data("new".utf8))
        #expect(merged.files[0].contentVersion == remote.files[0].contentVersion)
        #expect(merged.files[0].contentVersion != original.contentVersion)
    }

    @Test
    func metadataOnlyLocalReferenceMatchesSameVersionBytes() throws {
        let attachmentID = UUID()
        let version = UUID()
        let complete = Attachment(
            id: attachmentID, contentVersion: version,
            name: "file.txt", data: Data("payload".utf8))
        let missing = Attachment(
            id: attachmentID, contentVersion: version,
            name: "file.txt", data: nil)
        var base = Card(title: "Account")
        base.files = [complete]
        var local = base
        local.files = [missing]
        var remote = base
        remote.favorite = true

        let baseline = RowSyncBaseline(item: .card(base))
        #expect(baseline.matches(.card(local)))
        #expect(DatabaseItem.card(local).hasUnavailableAttachmentContent)
        #expect(!DatabaseItem.card(base).hasUnavailableAttachmentContent)
        let merged = try #require(card(baseline.merging(
            local: .card(local), remote: .card(remote))))
        #expect(merged.favorite)
        #expect(merged.files.first?.data == complete.data)
        #expect(merged.files.first?.contentVersion == version)
    }

    @Test
    func sameVersionDifferentAvailableBytesAreRejected() {
        let attachmentID = UUID()
        let version = UUID()
        var base = Card(title: "Account")
        base.files = [Attachment(
            id: attachmentID, contentVersion: version,
            name: "file.txt", data: Data("base".utf8))]
        var local = base
        local.files[0] = Attachment(
            id: attachmentID, contentVersion: version,
            name: "file.txt", data: Data("local".utf8))
        var remote = base
        remote.files[0] = Attachment(
            id: attachmentID, contentVersion: version,
            name: "file.txt", data: Data("remote".utf8))

        #expect(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote)) == nil)
    }

    @Test
    func rejectsAttachmentDeletionRacingWithReplacement() {
        let original = Attachment(name: "file.txt", data: Data("old".utf8))
        var base = Card(title: "Account")
        base.files = [original]
        var local = base
        local.files = []
        var remote = base
        remote.files[0].data = Data("new".utf8)

        #expect(RowSyncBaseline(item: .card(base)).merging(
            local: .card(local), remote: .card(remote)) == nil)
    }

    private func card(_ item: DatabaseItem?) -> Card? {
        guard case let .card(card) = item else { return nil }
        return card
    }

    private func label(_ item: DatabaseItem?) -> CardLabel? {
        guard case let .label(label) = item else { return nil }
        return label
    }

    private func profile(_ item: DatabaseItem?) -> UserProfile? {
        guard case let .userProfile(profile) = item else { return nil }
        return profile
    }
}
