import XCTest
@testable import UPasswords

/// Touch ID 快速解锁的钥匙串副本(无 ACL 项)存取回归。
/// evaluatePolicy 的生物识别弹窗无法自动化,这里只覆盖项的保存/存在性/读取/删除。
final class TouchIDKeychainTests: XCTestCase {
    private let dbName = "TouchIDTestsDB"

    override func tearDown() {
        PasswordStore.removeBiometricPassword(databaseName: dbName)
        super.tearDown()
    }

    func testSaveHasReadRemoveBiometricItem() {
        XCTAssertFalse(PasswordStore.hasBiometricItem(databaseName: dbName),
                       "fresh database name must have no biometric item")

        PasswordStore.savePasswordForBiometric("pw-测试-1234", databaseName: dbName)
        XCTAssertTrue(PasswordStore.hasBiometricItem(databaseName: dbName))

        XCTAssertEqual(PasswordStore.loadPassword(databaseName: dbName, biometric: true),
                       "pw-测试-1234")

        // 覆盖保存(换密码后再开 Touch ID 的路径)
        PasswordStore.savePasswordForBiometric("rotated-pw", databaseName: dbName)
        XCTAssertEqual(PasswordStore.loadPassword(databaseName: dbName, biometric: true),
                       "rotated-pw")

        PasswordStore.removeBiometricPassword(databaseName: dbName)
        XCTAssertFalse(PasswordStore.hasBiometricItem(databaseName: dbName))
        XCTAssertNil(PasswordStore.loadPassword(databaseName: dbName, biometric: true))
    }
}
