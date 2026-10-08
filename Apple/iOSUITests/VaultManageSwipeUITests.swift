import XCTest

/// 真实用户流端到端:建库/解锁 → 设置 Tab → 点开管理密码库 →
/// 三种滑动动态(慢拖/快速轻扫/屏幕左缘起手)右滑 Main 行 →
/// 断言 删除/切换 按钮真实存在且可点,截图留档;最后点删除验证确认弹窗。
/// 注:XCTest 自带 swipeRight() 的合成轨迹不代表真实手指,轻扫用显式
/// 参数拖动(速度 2500pt/s,与真机轻扫一致)。
final class VaultManageSwipeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testRealFlowSwipeRevealsActions() {
        let app = XCUIApplication()
        // 锁定中文:按钮/Tab 文案断言依赖本地化字符串
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        unlockOrCreate(app)
        openManageSheetViaRealNavigation(app)

        let row = app.staticTexts["Main"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "vault row missing")
        sleep(1)
        let y = row.frame.midY

        // ① 慢拖(行中部起手,600pt/s)
        dragRight(app, fromX: 120, toX: 370, y: y, velocity: 600)
        assertActionsRevealed(app, step: "slow-drag")

        // ② 收起后快速轻扫(2500pt/s,贴近真机手指)
        collapse(app, y: y)
        dragRight(app, fromX: 120, toX: 370, y: y, velocity: 2500)
        assertActionsRevealed(app, step: "fast-flick")

        // ③ 收起后屏幕最左缘起手(用户揭示 leading 按钮的肌肉记忆)
        collapse(app, y: y)
        dragRight(app, fromX: 6, toX: 300, y: y, velocity: 2500)
        assertActionsRevealed(app, step: "screen-edge")
    }

    /// 滑动揭示后按钮必须真实可用:点删除 → 出确认弹窗 → 取消。
    func testRevealedDeleteButtonOpensConfirmDialog() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        unlockOrCreate(app)
        openManageSheetViaRealNavigation(app)

        let row = app.staticTexts["Main"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "vault row missing")
        sleep(1)

        dragRight(app, fromX: 120, toX: 370, y: row.frame.midY, velocity: 2500)
        let delete = app.buttons["删除密码库"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "delete action not revealed")
        delete.tap()

        // 确认弹窗标题出现即证明滑动按钮真实可用;iOS 27 上 confirmationDialog
        // 的取消按钮不进无障碍树(画面有、AX 查不到),故不断言/不点取消
        let dialogTitle = app.staticTexts["删除密码库？"]
        XCTAssertTrue(dialogTitle.waitForExistence(timeout: 3), "delete confirm dialog missing")
        attach(app, "delete-confirm-dialog")
    }

    // MARK: helpers

    /// 首次启动走建库流程,已建库走解锁流程。
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

    /// 真实导航:设置 Tab → 密码库 子页 → 管理密码库 入口 → 弹层出现。
    private func openManageSheetViaRealNavigation(_ app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8), "settings tab missing")
        settingsTab.tap()

        let vaultsEntry = app.staticTexts["密码库"]
        XCTAssertTrue(vaultsEntry.waitForExistence(timeout: 5), "vaults settings entry missing")
        vaultsEntry.tap()

        let entry = app.staticTexts["管理密码库"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "manage vaults entry missing")
        entry.tap()

        let title = app.navigationBars["管理密码库"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "manage sheet not presented")
    }

    /// 断言两个操作按钮都存在且可点,并截图留档。
    private func assertActionsRevealed(_ app: XCUIApplication, step: String) {
        let delete = app.buttons["删除密码库"]
        let swit = app.buttons["切换"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "\(step): delete action not revealed")
        XCTAssertTrue(delete.isHittable, "\(step): delete action not hittable")
        XCTAssertTrue(swit.exists, "\(step): switch action not revealed")
        attach(app, "revealed-\(step)")
    }

    /// 屏幕绝对坐标右拖(可从屏幕左缘起手)。
    private func dragRight(_ app: XCUIApplication, fromX: CGFloat, toX: CGFloat, y: CGFloat,
                           velocity: XCUIGestureVelocity) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: fromX, dy: y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: toX, dy: y)),
                   withVelocity: velocity, thenHoldForDuration: 0)
        sleep(1)
    }

    /// 左拖行位置收起已揭示的操作。
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
