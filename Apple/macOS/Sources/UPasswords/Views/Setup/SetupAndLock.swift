import SwiftUI
import AppKit
import LocalAuthentication
import UniformTypeIdentifiers
import UPasswordsCore
import UPasswordsPersistence

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
                .foregroundStyle(titleColor)

            Spacer().frame(height: 13)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(titleColor.opacity(0.8))

            Spacer().frame(height: 10)

            // 当前解锁目标库名胶囊:锁屏不再让人猜输哪个库的密码
            if !ctx.databaseName.isEmpty {
                Label(ctx.databaseName, systemImage: "cylinder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(titleColor.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(titleColor.opacity(0.12), in: Capsule())
            }

            Spacer().frame(height: 12)

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
            // 背景:桌面壁纸模糊压暗(macOS 原生风格)/质感渐变/自定图片,跟随设置
            LockScreenBackground.view(
                kind: settings.lockBackgroundKind,
                textureIndex: settings.lockTexture,
                imageName: settings.lockBackgroundImageName
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
            // 自定图片文件缺失(被手动删除等)时已回退渐变,留 warn 便于排查
            if settings.lockBackgroundKind == .image,
               LockScreenImageStore.image(named: settings.lockBackgroundImageName) == nil {
                Log.warn("app", "lock bg image missing, fallback gradient name=\(settings.lockBackgroundImageName)")
            }
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

    /// 文字颜色跟随「锁屏文字」设置(字面黑/白,非语义色)。
    private var titleColor: Color {
        settings.lockWhiteText ? .white : .black
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
        Task { @MainActor in
            // 远端兜底:他机改密轮换后本地本体过期,需拉远端收敛(见 AppContext 注释)
            switch await ctx.unlockWithRemoteFallback(name: ctx.databaseName, password: password) {
            case .success:
                password = ""
                error = ""
            case .wrongPassword:
                error = L10n.t("wrong_password_error")
                ctx.registerFailedAttempt()
                password = ""
            case .unavailable:
                // 数据损坏/信封缺失/断网:不是密码错,绝不计入自毁
                error = L10n.t("unlock_environment_error")
                password = ""
            }
        }
    }
}

/// First-run wizard: 初始化数据库,两条路径
/// (create new / restore from cloud)。
struct SetupWindowView: View {
    @EnvironmentObject var ctx: AppContext

    private enum SetupMode { case account, create, restoreCloud, restoreLocal }

    @State private var mode: SetupMode = .create
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var touchID = true
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            PhaseTitleBar(title: L10n.tBranded("app_title"))
            Text(L10n.t("database_setup_title"))
                .font(.title2.bold())
                .padding(.top, 24)
            Text(L10n.tBranded("app_title"))
                .font(.callout)
                .foregroundStyle(.secondary)

            if mode == .account {
                // 新装引导第一步:注册/登录先于建库(库就绪后自动补绑云同步)
                AccountStepView(onDone: {
                    mode = .create
                })
            } else if mode == .create {
                Spacer()
                createForm
                Spacer()

                if !error.isEmpty {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Button(L10n.t("restore_from_cloud_button")) {
                        Log.info("ui", "setup: switch to cloud restore")
                        error = ""
                        mode = .restoreCloud
                    }
                    Button(L10n.t("restore_from_local_button")) {
                        Log.info("ui", "setup: switch to local restore")
                        error = ""
                        mode = .restoreLocal
                    }
                    Button(L10n.t("continue_button"), action: create)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.isEmpty || password.isEmpty)
                }
                .padding(.bottom, 28)
            } else if mode == .restoreCloud {
                RestoreCloudForm(onBack: {
                    Log.info("ui", "setup: back to create from cloud restore")
                    mode = .create
                })
            } else {
                RestoreLocalForm(onBack: {
                    Log.info("ui", "setup: back to create from local restore")
                    mode = .create
                })
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(.regularMaterial)
        .background(WindowChromeConfigurator(mode: .plain))
        .onAppear {
            if ctx.relayOnboardingNeeded {
                Log.info("ui", "setup: account step shown first (fresh install, never signed in)")
                mode = .account
            }
        }
    }

    private var createForm: some View {
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
        }
        .padding(.horizontal, 60)
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
        guard password.count >= PasswordPolicy.minimumMasterPasswordLength else {
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

/// 新装引导第一步:邮箱验证码注册/登录(先于创建/恢复库完成,必经无跳过)。
/// 库就绪后由 AppContext.relayBindCurrentVaultIfNeeded 自动补绑云同步。
private struct AccountStepView: View {
    @EnvironmentObject var ctx: AppContext
    var onDone: () -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @StateObject private var resend = ResendCountdown()
    @State private var error = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(L10n.t("relay_onboarding_title"))
                .font(.title2.bold())
            Text(L10n.t("relay_onboarding_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(label: L10n.t("relay_email_placeholder")) {
                        TextField("", text: $email)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("relay_code_placeholder")) {
                        SecureField("", text: $code)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .frame(maxWidth: 380)
            }
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button(resend.buttonTitle(L10n.t("relay_send_code_button"))) {
                    Log.info("ui", "setup: onboarding code request")
                    busy = true
                    let address = email.trimmingCharacters(in: .whitespaces)
                    Task {
                        resend.start(await ctx.relaySendCode(email: address))
                        busy = false
                    }
                }
                .disabled(!email.contains("@" ) || busy || resend.isRunning)
                Button(L10n.t("relay_login_button")) {
                    Log.info("ui", "setup: onboarding login")
                    busy = true
                    let address = email.trimmingCharacters(in: .whitespaces)
                    let entered = code
                    code = ""
                    Task {
                        if await ctx.relayLoginOnly(email: address, code: entered) {
                            onDone()
                        }
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || code.count < RelayClient.verificationCodeLength || busy)
            }
            .padding(.bottom, 28)
            Spacer()
        }
    }
}

/// 向导「在线恢复」表单:自动从服务端注册表列出账户名下的库 →
/// 选一个并输入该库主密码 → 服务端信封 + 库体镜像解密落为本地库,
/// 直接进入主界面。尚无服务端镜像的库行尾标注(在原设备同步一次后即可恢复);
/// 离线迁移走「本地还原」(.upw/.upwkey 文件对)。
struct RestoreCloudForm: View {
    @EnvironmentObject var ctx: AppContext
    var onBack: () -> Void

    @State private var restoring = false
    @State private var serverVaults: [RelayClient.VaultRecord] = []
    @State private var loaded = false
    @State private var selected = ""
    @State private var password = ""
    @State private var error = ""

    /// 选中即可恢复:v7 行级同步下空库同样合法(信封+0 行 → 空库接管,
    /// 其他设备同步后的条目随后拉取)。不再设"有镜像才可恢复"的 v6 遗留门槛
    /// ——该门槛曾让选中空库时"恢复并打开"永久禁用。
    private var selectedRecord: RelayClient.VaultRecord? {
        serverVaults.first(where: { $0.name == selected })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    setupItem(2) { Text(L10n.t("database_setup_item_2")) }
                        .font(.body.bold())
                        .foregroundStyle(.primary)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if !loaded {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.t("cloud_restore_loading_hint"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            } else if serverVaults.isEmpty {
                                Text(L10n.t("cloud_restore_empty_hint"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("", selection: $selected) {
                                    ForEach(serverVaults.map(\.name), id: \.self) { n in
                                        Text(n).tag(n)
                                    }
                                }
                                .pickerStyle(.radioGroup)
                                .labelsHidden()
                                Text(L10n.t("cloud_restore_server_list_hint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 420)
                    }

                    LabeledRow(label: L10n.t("password_prompt")) {
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(L10n.t("cloud_restore_password_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !error.isEmpty {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 10)
            }

            HStack {
                Button(L10n.t("cancel_button"), action: onBack)
                Button {
                    Log.info("ui", "online restore: restore \"\(selected)\"")
                    Task { await restore() }
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.t("restore_ok_button"))
                        if restoring { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRecord == nil || password.isEmpty || restoring)
            }
            .padding(.bottom, 28)
        }
        .task {
            // 引导账户步登录在先:进入本表单即从注册表列出账户名下的库
            if let records = await ctx.relayVaultsForRestore() {
                serverVaults = records
                selected = records.first?.name ?? ""
            }
            loaded = true
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

    private func restore() async {
        guard let record = selectedRecord else { return }
        restoring = true
        error = ""
        do {
            try await ctx.restoreDatabaseFromRelay(record: record, password: password)
            // 成功即 phase → .unlocked,RootView 自动切主界面,本视图随之销毁
        } catch let err {
            error = err.localizedDescription
        }
        restoring = false
    }
}

/// 向导「本地还原」表单:选择从其他设备拷来的一对 `<名>.upw`(本体)/
/// `<名>.upwkey`(信封)文件 → 输入该库主密码 → 校验解密落为本地库,
/// 直接进入主界面。无云端通道(未配 WebDAV/iCloud)时的迁移路径。
struct RestoreLocalForm: View {
    @EnvironmentObject var ctx: AppContext
    var onBack: () -> Void

    @State private var bodyURL: URL?
    @State private var envelopeURL: URL?
    @State private var envelopeAutoFound = false
    @State private var name = ""
    @State private var password = ""
    @State private var error = ""
    @State private var restoring = false

    /// 信封与密码齐备才允许恢复;库名交由 store 校验(非法/重名在恢复时报错)。
    private var readyToRestore: Bool {
        bodyURL != nil && envelopeURL != nil && !name.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    setupItem(3) { Text(L10n.t("database_setup_item_3")) }
                        .font(.body.bold())
                        .foregroundStyle(.primary)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledRow(label: L10n.t("database_name_prompt")) {
                                TextField("Main", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            LabeledRow(label: L10n.t("local_vault_file_prompt")) {
                                HStack(spacing: 8) {
                                    Button(bodyURL == nil
                                           ? L10n.t("local_pick_file_button")
                                           : bodyURL?.lastPathComponent ?? "") {
                                        pickBodyFile()
                                    }
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    if bodyURL != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            LabeledRow(label: L10n.t("local_key_file_prompt")) {
                                HStack(spacing: 8) {
                                    Button(envelopeURL == nil
                                           ? L10n.t("local_pick_key_button")
                                           : envelopeURL?.lastPathComponent ?? "") {
                                        pickKeyFile()
                                    }
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    if envelopeURL != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            if bodyURL != nil && envelopeURL == nil {
                                Label(L10n.t("local_key_missing_hint"), systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if envelopeAutoFound {
                                Label(L10n.t("local_key_autofound_hint"), systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 420)
                    }

                    LabeledRow(label: L10n.t("password_prompt")) {
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(L10n.t("local_restore_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !error.isEmpty {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 10)
            }

            HStack {
                Button(L10n.t("cancel_button"), action: onBack)
                Button {
                    Log.info("ui", "local restore: restore \"\(name)\"")
                    Task { await restore() }
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.t("restore_ok_button"))
                        if restoring { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!readyToRestore || restoring)
            }
            .padding(.bottom, 28)
        }
    }

    /// 所选本体旁的同名信封(`<名>.upw` → `<名>.upwkey`)。
    private func siblingKeyURL(for body: URL) -> URL? {
        let candidate = body.deletingPathExtension().appendingPathExtension("upwkey")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// 选本体文件:预填库名并自动探测同目录信封。
    private func pickBodyFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("restore_from_local_title")
        panel.allowedContentTypes = [UTType(filenameExtension: "upw")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.info("ui", "local restore: body pick cancelled")
            return
        }
        Log.info("ui", "local restore: body picked \(url.lastPathComponent)")
        bodyURL = url
        // 库名预填文件名(备份戳含连字符等非法字符时由恢复时的校验兜底)
        name = url.deletingPathExtension().lastPathComponent
        if let key = siblingKeyURL(for: url) {
            envelopeURL = key
            envelopeAutoFound = true
            Log.info("ui", "local restore: sibling envelope found \(key.lastPathComponent)")
        } else {
            envelopeURL = nil
            envelopeAutoFound = false
        }
        error = ""
    }

    /// 手动选信封文件(本体旁没有同名 .upwkey 时)。
    private func pickKeyFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("restore_from_local_title")
        panel.allowedContentTypes = [UTType(filenameExtension: "upwkey")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.info("ui", "local restore: key pick cancelled")
            return
        }
        Log.info("ui", "local restore: key picked \(url.lastPathComponent)")
        envelopeURL = url
        envelopeAutoFound = false
        error = ""
    }

    private func restore() async {
        guard let body = bodyURL, let envelope = envelopeURL else { return }
        restoring = true
        error = ""
        do {
            try await ctx.restoreDatabaseFromLocalFiles(
                body: body, envelope: envelope, name: name, password: password)
            // 成功即 phase → .unlocked,RootView 自动切主界面,本视图随之销毁
        } catch let err {
            error = err.localizedDescription
        }
        restoring = false
    }

    private func setupItem(_ n: Int, @ViewBuilder title: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            title()
        }
    }
}
