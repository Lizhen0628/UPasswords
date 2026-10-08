import XCTest

/// 滑动动态矩阵探针:对管理密码库 Main 行施加不同 时长×速度×行程 的右滑,
/// 打印每种组合是否揭示操作按钮,用于定位快速轻扫失效的确切边界。
final class SwipeMatrixProbeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testSwipeMatrix() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        unlockOrCreate(app)
        openManageSheet(app)

        let row = app.staticTexts["Main"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "vault row missing")
        sleep(1)
        let y = row.frame.midY

        // (标签, 起点x, 终点x, 预按压秒, 速度pt/s)
        let cases: [(String, CGFloat, CGFloat, TimeInterval, XCUIGestureVelocity)] = [
            ("slow-250pt", 120, 370, 0.10, XCUIGestureVelocity(600)),
            ("fast-v1500", 120, 370, 0.05, XCUIGestureVelocity(1500)),
            ("flick-v2500", 120, 370, 0.02, XCUIGestureVelocity(2500)),
            ("flick-v4000", 120, 370, 0.01, XCUIGestureVelocity(4000)),
            ("short-80pt-v2500", 120, 200, 0.02, XCUIGestureVelocity(2500)),
            ("edge6-v2500", 6, 300, 0.03, XCUIGestureVelocity(2500)),
        ]

        for (name, fromX, toX, hold, velocity) in cases {
            collapse(app, y: y)
            let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            origin.withOffset(CGVector(dx: fromX, dy: y))
                .press(forDuration: hold, thenDragTo: origin.withOffset(CGVector(dx: toX, dy: y)),
                       withVelocity: velocity, thenHoldForDuration: 0)
            sleep(1)
            let revealed = app.buttons["删除密码库"].exists
            print("PROBE-MATRIX [\(name)] revealed=\(revealed)")
            if revealed {
                attach(app, "matrix-\(name)")
            }
        }

        // 元素自带 swipeRight() 快速轻扫对照
        collapse(app, y: y)
        row.swipeRight()
        sleep(1)
        print("PROBE-MATRIX [element-swipeRight] revealed=\(app.buttons["删除密码库"].exists)")

        // 元素自带 press+drag 慢速对照
        collapse(app, y: y)
        let rowStart = row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        rowStart.press(forDuration: 0.1, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 2.2, dy: 0.5)))
        sleep(1)
        print("PROBE-MATRIX [element-slowdrag] revealed=\(app.buttons["删除密码库"].exists)")
    }

    // MARK: helpers

    private func unlockOrCreate(_ app: XCUIApplication) {
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
    }

    private func openManageSheet(_ app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8), "settings tab missing")
        settingsTab.tap()
        let vaultsEntry = app.staticTexts["密码库"]
        XCTAssertTrue(vaultsEntry.waitForExistence(timeout: 5), "vaults settings entry missing")
        vaultsEntry.tap()
        let entry = app.staticTexts["管理密码库"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "manage entry missing")
        entry.tap()
        XCTAssertTrue(app.navigationBars["管理密码库"].waitForExistence(timeout: 5), "sheet missing")
    }

    private func collapse(_ app: XCUIApplication, y: CGFloat) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: 340, dy: y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 100, dy: y)),
                   withVelocity: XCUIGestureVelocity(2000), thenHoldForDuration: 0)
        sleep(1)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
