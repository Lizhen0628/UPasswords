import Foundation
import CryptoKit

import UPasswordsCore

/// upasswords.com 信封同步通道(零知识加速器)。
///
/// v2 信封加密下,改主密码只产生 ~100B 的新信封;本通道负责让信封以强一致、
/// 毫秒级的方式在设备间传播,弥补 iCloud/WebDAV 的弱一致延迟。
///
/// 零知识设计:
/// - vaultID 与 accessToken 均由库密钥经 HKDF-SHA256 派生(不同 info),
///   任何持有库密钥的设备(解锁后)自动获得同一身份,新设备零配置加入;
/// - 服务端只存 SHA-256(accessToken) 与信封密文,无法解密、无法关联用户;
/// - 主密码、库密钥绝不出设备(隐私红线)。
public enum CloudEnvelopeService {
    /// 远端信封记录。
    public struct RemoteEnvelope: Sendable {
        public let rev: Int
        public let changedAt: Date
        public let envelope: Data
    }

    // 逻辑保证:合法字面量 URL
    private static let baseURL = URL(string: "https://api.upasswords.com")!

    /// 库身份:hex(HKDF-SHA256(vaultKey, salt="upw-cloud-v1", info="vault-id"))。
    public static func vaultID(vaultKey: SymmetricKey) -> String {
        deriveHex(vaultKey: vaultKey, info: "vault-id")
    }

    /// 访问令牌(只在请求头出现,服务端存其 SHA-256)。
    static func accessToken(vaultKey: SymmetricKey) -> String {
        deriveHex(vaultKey: vaultKey, info: "access-token")
    }

    private static func deriveHex(vaultKey: SymmetricKey, info: String) -> String {
        let material = vaultKey.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data("upw-cloud-v1".utf8),
            info: Data(info.utf8),
            outputByteCount: 32)
        return key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// 拉取远端信封;404/网络错误返回 nil(通道为尽力而为的加速器,不影响主同步)。
    public static func fetch(vaultKey: SymmetricKey) async -> RemoteEnvelope? {
        let url = baseURL.appendingPathComponent("v1/vaults/\(vaultID(vaultKey: vaultKey))/envelope")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rev = json["rev"] as? Int,
                  let changedAt = json["changedAt"] as? Double,
                  let envelope64 = json["envelope"] as? String,
                  let envelope = Data(base64Encoded: envelope64) else { return nil }
            return RemoteEnvelope(
                rev: rev,
                changedAt: Date(timeIntervalSince1970: changedAt),
                envelope: envelope)
        } catch {
            Log.debug("sync", "cloud api fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 推送本地信封(changedAt 决胜,过期写被服务端拒绝)。
    /// - Parameters:
    ///   - vaultKey: 当前库密钥(会话持有)
    ///   - envelope: 本地信封密文
    ///   - changedAt: 信封改密时间戳
    public static func push(vaultKey: SymmetricKey, envelope: Data, changedAt: Date) async {
        let id = vaultID(vaultKey: vaultKey)
        let url = baseURL.appendingPathComponent("v1/vaults/\(id)/envelope")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken(vaultKey: vaultKey))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "envelope": envelope.base64EncodedString(),
            "changedAt": changedAt.timeIntervalSince1970,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.info("sync", "cloud api envelope push vault=\(id.prefix(8))… status=\(code)")
        } catch {
            Log.warn("sync", "cloud api envelope push failed: \(error.localizedDescription)")
        }
    }
}
