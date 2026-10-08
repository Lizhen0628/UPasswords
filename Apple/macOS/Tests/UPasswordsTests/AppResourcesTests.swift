import XCTest
import UPasswordsCore
@testable import UPasswords

/// 双构建资源接缝:SPM 构建走 Bundle.module,xcodeproj 构建走 .main,
/// AppResources 必须在这两套构建下都能拿到菜单栏图标;
/// 同时验证应用进程内 Core 包的本地化表可用(跨包资源 wiring)。
final class AppResourcesTests: XCTestCase {
    func testMenuBarIconAvailable() {
        XCTAssertNotNil(AppResources.bundle.url(forResource: "MenuBarKeys", withExtension: "png"),
                        "MenuBarKeys.png missing from AppResources.bundle")
    }

    func testCoreLocalizationAvailableInAppProcess() {
        XCTAssertEqual(L10n.t("app_title"), "UPasswords")
        XCTAssertFalse(L10n.db("password_type").isEmpty)
    }
}
