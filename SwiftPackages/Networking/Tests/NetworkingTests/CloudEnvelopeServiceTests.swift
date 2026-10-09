import XCTest
import CryptoKit

@testable import UPasswordsNetworking

final class CloudEnvelopeServiceTests: XCTestCase {
    /// 派生稳定性:同一库密钥必得同一 vaultID(双端自动一致的前提)。
    func testVaultIDDeterministic() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertEqual(
            CloudEnvelopeService.vaultID(vaultKey: key),
            CloudEnvelopeService.vaultID(vaultKey: key))
        XCTAssertEqual(CloudEnvelopeService.vaultID(vaultKey: key).count, 64)
    }

    /// vaultID 与 accessToken 使用不同 info 派生,不得相同(最小授权)。
    func testTokenDiffersFromID() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertNotEqual(
            CloudEnvelopeService.vaultID(vaultKey: key),
            CloudEnvelopeService.accessToken(vaultKey: key))
    }

    /// 不同库密钥 → 不同身份(库隔离)。
    func testDistinctKeysDistinctIDs() {
        XCTAssertNotEqual(
            CloudEnvelopeService.vaultID(vaultKey: SymmetricKey(size: .bits256)),
            CloudEnvelopeService.vaultID(vaultKey: SymmetricKey(size: .bits256)))
    }
}
