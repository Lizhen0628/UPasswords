import SwiftUI
import AppKit
import LocalAuthentication

/// LockWindowController — Safe 锁屏 1:1:普通标题栏小窗(500×380),
/// 应用图标(黄圆+白盾+钥匙孔)居中;「输入密码:」左对齐 + 输入框与
/// 「确定」同行 + 「显示密码」复选框;底部左侧 Touch ID、右侧「?」帮助。
struct LockWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var password = ""
    @State private var showPassword = false
    @State private var error = ""
    @State private var shake = false
    @State private var touchIDAsked = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            appIcon

            Spacer().frame(height: 38)

            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.t("enter_password_prompt"))
                    .font(.system(size: 13))
                    .foregroundStyle(textStyle)
                HStack(spacing: 8) {
                    passwordField
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(unlock)
                    Button(L10n.t("ok_button"), action: unlock)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Toggle(L10n.t("show_password_button"), isOn: $showPassword)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(textStyle)
                if !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 320)
            .offset(x: shake ? -8 : 0)
            .animation(.default.repeatCount(3, autoreverses: true), value: shake)

            Spacer()

            HStack(spacing: 10) {
                if ctx.touchIDAvailable && settings.fastUnlock {
                    Button {
                        if ctx.hasBiometricItem {
                            ctx.unlockWithTouchID()
                        } else {
                            // 生物识别副本不存在(向导时未勾选/旧版本保存失败)
                            error = L10n.t("touch_id_not_set_hint")
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "touchid")
                                .font(.system(size: 21))
                            Text(L10n.t("touch_id_button"))
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(textStyle.opacity(0.85))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("fast_unlock_setting"))
                }
                if ctx.dbsInfo().count > 1 {
                    Button(L10n.t("select_database_title")) {
                        ctx.activeSheet = .selectDatabase
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(textStyle.opacity(0.7))
                }
                Spacer()
                Button {
                    NSApp.showHelp(nil)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(textStyle.opacity(0.6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LockTextures.gradient(for: settings.lockTexture).ignoresSafeArea())
        .background(WindowChromeConfigurator(mode: .lock))
        .preferredColorScheme(nil)
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
            // 与 Safe 一致:进入锁屏自动弹出一次 Touch ID(需已保存生物识别副本)
            if !touchIDAsked, ctx.touchIDAvailable, settings.fastUnlock, ctx.hasBiometricItem {
                touchIDAsked = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    ctx.unlockWithTouchID()
                }
            }
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        if showPassword {
            TextField("", text: $password)
        } else {
            SecureField("", text: $password)
        }
    }

    /// Safe 图标:黄色径向圆 + 白盾 + 黑钥匙孔。
    private var appIcon: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.86, blue: 0.38),
                             Color(red: 0.97, green: 0.72, blue: 0.18)],
                    startPoint: .top, endPoint: .bottom))
            Image(systemName: "shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
            VStack(spacing: 1) {
                Circle().fill(.black).frame(width: 10, height: 10)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.black)
                    .frame(width: 4.5, height: 11)
            }
            .offset(y: 2)
        }
        .frame(width: 78, height: 78)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    private var textStyle: Color {
        settings.lockWhiteText ? .white : .primary
    }

    private func unlock() {
        do {
            try ctx.unlock(name: ctx.databaseName, password: password)
            password = ""
            error = ""
        } catch let err {
            error = err.localizedDescription
            ctx.registerFailedAttempt()
            shake.toggle()
            password = ""
        }
    }
}

/// SetupWindowController — first-run wizard: 初始化数据库 with the original's
/// three options (create new / restore from cloud / restore from local file).
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
            Text(L10n.t("database_setup_title"))
                .font(.title2.bold())
                .padding(.top, 32)
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

struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            content.frame(maxWidth: .infinity)
        }
    }
}

extension L10n {
    /// Key with a fallback for keys absent from the original tables.
    static func t(_ key: String, fallback: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        return v == key ? fallback : v
    }
}
