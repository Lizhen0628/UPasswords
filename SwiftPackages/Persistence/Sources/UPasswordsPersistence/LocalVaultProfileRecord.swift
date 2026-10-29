import Foundation
import SwiftData

/// Encrypted local row matching the cloud `vault_user_profiles` business table.
@Model
public final class LocalVaultProfileRecord {
    @Attribute(.unique) public var rowKey: String
    public var vaultID: String
    public var itemUUID: String
    public var kind: Int16
    public var revision: Int64
    public var body: Data
    public var bodySHA256: String
    public var bodyBytes: Int64
    public var modifiedMS: Int64
    public var createdMS: Int64
    public var updatedMS: Int64
    public var originSessionID: String?
    public var originDeviceName: String
    public var originPlatform: String

    public init(
        vaultID: String,
        itemUUID: String,
        revision: Int64,
        body: Data,
        bodySHA256: String,
        bodyBytes: Int64,
        modifiedMS: Int64,
        createdMS: Int64,
        updatedMS: Int64,
        originSessionID: String? = nil,
        originDeviceName: String = "",
        originPlatform: String = "other"
    ) {
        self.rowKey = "\(vaultID):\(itemUUID.lowercased())"
        self.vaultID = vaultID
        self.itemUUID = itemUUID.lowercased()
        self.kind = 3
        self.revision = revision
        self.body = body
        self.bodySHA256 = bodySHA256
        self.bodyBytes = bodyBytes
        self.modifiedMS = modifiedMS
        self.createdMS = createdMS
        self.updatedMS = updatedMS
        self.originSessionID = originSessionID
        self.originDeviceName = originDeviceName
        self.originPlatform = originPlatform
    }
}
