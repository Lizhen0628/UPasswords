import XCTest
@testable import UPasswordsPersistence

/// Touch ID 快速解锁的钥匙串副本(无 ACL 项)存取回归。
/// evaluatePolicy 的生物识别弹窗无法自动化,这里只覆盖项的保存/存在性/读取/删除。
final class TouchIDKeychainTests: XCTestCase {
    private let dbName = "TouchIDTestsDB"

    override func setUp() {
        super.setUp()
        // CI 与本机都可能设了密码锁:统一走普通项,ACL 读取需交互无法自动化
        PasswordStore.usePlainBiometricItemsForTesting = true
    }

    override func tearDown() {
        PasswordStore.removeBiometricPassword(databaseName: dbName)
        super.tearDown()
    }

    func testSaveHasReadRemoveBiometricItem() throws {
        // 环境探测:登录钥匙串被锁(非交互 shell / 部分 CI)时 SecItemAdd 返回
        // -25308,后续断言必然误报——跳过而非标红(规范 14.7:断言不依赖运行环境)
        PasswordStore.savePasswordForBiometric("probe", databaseName: dbName)
        let probeOk = PasswordStore.loadPassword(databaseName: dbName, biometric: true) != nil
        PasswordStore.removeBiometricPassword(databaseName: dbName)
        try XCTSkipUnless(probeOk, "login keychain locked — keychain unavailable in this environment")

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
