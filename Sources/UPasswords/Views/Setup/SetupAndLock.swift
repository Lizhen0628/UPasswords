import SwiftUI
import AppKit
import LocalAuthentication

/// 窗口级隐藏标题栏(.windowStyle(.hiddenTitleBar))下,锁屏/向导窗的标题条:
/// 红绿灯占位 + 居中标题 + 可拖动区。红绿灯由系统绘制在条带左上角。
struct PhaseTitleBar: View {
    var title: String
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: 76) // 红绿灯占位
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 27)
            .background(WindowDragArea())
            if showsDivider { Divider() }
        }
    }
}

/// 锁定窗 — 系统锁定风格:应用图标 + Touch ID 徽章居中,
/// 「“xx” 已锁定」标题、说明文字、居中密码框(回车解锁),底部无按钮。
struct LockWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var password = ""
    @State private var error = ""
    @State private var touchIDAsked = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PhaseTitleBar(title: "", showsDivider: false)

            // 像素级蓝图(参考 982×780 → 500×380,比例 ~0.51):
            // 图标块顶 y≈102,方块 80×80,角标圆 53 右下外挂;
            // 标题中心 y≈215(16pt bold),副标题中心 y≈244(12pt);
            // 密码框 190×27 @ y≈273 居中,底部余白 ~80。
            Spacer().frame(height: 75)

            iconCluster

            Spacer().frame(height: 10)

            Text(L10n.tBranded("lock_window_locked_title"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Spacer().frame(height: 13)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.87))

            Spacer().frame(height: 21)

            passwordField

            if !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)   // 标题条贴窗口顶(红绿灯叠在其上)
        .background(
            // 背景:顶 #393A39 → 底 #272A2B 的对角微渐变
            LinearGradient(
                colors: [Color(red: 0.224, green: 0.227, blue: 0.224),
                         Color(red: 0.153, green: 0.165, blue: 0.169)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .background(WindowChromeConfigurator(mode: .lock))
        .preferredColorScheme(.dark)
        #if DEBUG
        // 复现锁屏→解锁过渡用:直接用钥匙串里存的密码解锁(自动化测试)
        .background(
            Button("debug-unlock") {
                if let pw = PasswordStore.loadPassword(databaseName: ctx.databaseName) {
                    try? ctx.unlock(name: ctx.databaseName, password: pw)
                }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
        )
        #endif
        .onAppear {
            fieldFocused = true
            // 进入锁屏自动弹出一次 Touch ID(需已保存生物识别副本)
            if !touchIDAsked, ctx.touchIDAvailable, settings.fastUnlock, ctx.hasBiometricItem {
                touchIDAsked = true
                // 存量 GCD:onAppear 在主线程,延时等首帧稳定后回调仍在主队列
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    ctx.unlockWithTouchID()
                }
            }
        }
    }

    /// 居中密码框(宽 190、总高 27、圆角 7、描边钢蓝 rgb(49,112,156)、
    /// 填充 #252523、placeholder #5B5B59 居中),回车解锁。
    private var passwordField: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(red: 0.145, green: 0.145, blue: 0.137))
            if password.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.32))
            }
            SecureField("", text: $password)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(unlock)
        }
        .frame(width: 190, height: 27)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(red: 0.19, green: 0.44, blue: 0.61),
                        lineWidth: fieldFocused ? 2 : 1)
                .shadow(color: Color(red: 0.19, green: 0.44, blue: 0.61).opacity(0.35), radius: 3)
        )
    }

    /// 应用图标(保留自家 logo)+ 右下角 Touch ID 徽章(仅设备支持时显示)。
    /// 方块 80×80 圆角 ~18,角标圆 53,粉 #FF375F,暗底 #1E1E1E,
    /// 徽章中心相对方块中心偏移 (+39.5, +26.5)。
    private var iconCluster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.118, green: 0.118, blue: 0.118))
                .frame(width: 80, height: 80)
                .overlay(
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                )
                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)

            if ctx.touchIDAvailable {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.118, green: 0.118, blue: 0.118))
                    Image(systemName: "touchid")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.216, blue: 0.373))
                }
                .frame(width: 53, height: 53)
                .overlay(Circle().stroke(Color(red: 0.224, green: 0.227, blue: 0.224), lineWidth: 4))
                .offset(x: 39.5, y: 26.5)
            }
        }
    }

    /// 说明文字:支持触控 ID 时与参考文案一致。
    private var subtitle: String {
        if ctx.touchIDAvailable && settings.fastUnlock {
            return L10n.tBranded("lock_window_unlock_touch_id_text")
        }
        return L10n.tBranded("lock_window_unlock_text")
    }

    private var placeholder: String {
        L10n.t("enter_password_prompt").trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
    }

    private func unlock() {
        do {
            try ctx.unlock(name: ctx.databaseName, password: password)
            password = ""
            error = ""
        } catch let err {
            error = err.localizedDescription
            ctx.registerFailedAttempt()
            password = ""
        }
    }
}

/// First-run wizard: 初始化数据库,三选一
/// (create new / restore from cloud / restore from local file).
struct SetupWindowView: View {
    @EnvironmentObject var ctx: AppContext

    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var touchID = true
    @State private var error = ""
    @State private var restoring = false

    var body: some View {
        VStack(spacing: 0) {
            PhaseTitleBar(title: L10n.tBranded("app_title"))
            Text(L10n.t("database_setup_title"))
                .font(.title2.bold())
                .padding(.top, 24)
            Text(L10n.tBranded("app_title"))
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                setupItem(1) { Text(L10n.t("database_setup_item_1")) }
                    .font(.body.bold())
                    .foregroundStyle(.primary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow(label: L10n.t("database_name_prompt")) {
                            TextField("Main", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("set_password_prompt")) {
                            SecureField("", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("confirm_password_prompt")) {
                            SecureField("", text: $confirm)
                                .textFieldStyle(.roundedBorder)
                        }
                        if PasswordStore.biometricAvailable() {
                            Toggle(L10n.t("touch_id_login_query"), isOn: $touchID)
                                .font(.callout)
                        }
                        Text(L10n.t("password_restore_warning"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 380)
                }

                Divider()

                setupItem(2) { Text(L10n.t("database_setup_item_2")) }
                    .font(.body)
                setupItem(3) { Text(L10n.t("database_setup_item_3")) }
                    .font(.body)

                Button(L10n.t("restore_from_cloud_button")) {
                    ctx.activeSheet = .selectDatabase
                }
                .disabled(true)
                .help(L10n.t("not_configured_state"))
            }
            .padding(.horizontal, 60)

            Spacer()

            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button(L10n.t("continue_button"), action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || password.isEmpty)
            }
            .padding(.bottom, 28)
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(.regularMaterial)
        .background(WindowChromeConfigurator(mode: .plain))
        .onAppear {
            if ctx.dbsInfo().isEmpty == false { restoring = true }
        }
    }

    private func setupItem(_ n: Int, @ViewBuilder title: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            title()
        }
    }

    private func create() {
        guard password.count >= 4 else {
            error = L10n.t("minimum_password_length_error")
            return
        }
        guard password == confirm else {
            error = L10n.t("passwords_do_not_match_error")
            return
        }
        do {
            try ctx.createDatabase(name: name, password: password, touchID: touchID)
        } catch let err {
            self.error = err.localizedDescription
        }
    }
}
