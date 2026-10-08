import XCTest

/// 探针:首页右上角「+」(新建条目)是否存在且可点。
/// 真机 iOS 27.0.1 用户报缺失,先在 iOS 27.0 模拟器对照验证。
final class HomePlusProbeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testHomePlusButtonExists() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let fields = app.descendants(matching: .secureTextField)
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10), "no password field")
        if fields.count >= 2 {
            fields.element(boundBy: 0).tap()
            fields.element(boundBy: 0).typeText("test1234")
            fields.element(boundBy: 1).tap()
            fields.element(boundBy: 1).typeText("test1234\n")
        } else {
            fields.element(boundBy: 0).tap()
            fields.element(boundBy: 0).typeText("test1234\n")
        }

        XCTAssertTrue(app.tabBars.buttons["密码"].waitForExistence(timeout: 8), "home tab missing")
        sleep(1)

        let plus = app.buttons["新建条目"]
        print("PROBE-PLUS exists=\(plus.exists) hittable=\(plus.isHittable)")
        // 列出导航栏全部按钮,定位「+」到底渲染没渲染
        let navBar = app.navigationBars.firstMatch
        print("PROBE-PLUS navbar buttons: \(navBar.buttons.allElementsBoundByIndex.map { $0.label })")
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "home-plus-probe"
        a.lifetime = .keepAlways
        add(a)
        XCTAssertTrue(plus.waitForExistence(timeout: 3), "home + button missing")
    }
}
