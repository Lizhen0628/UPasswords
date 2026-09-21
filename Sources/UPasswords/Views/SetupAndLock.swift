import SwiftUI
import LocalAuthentication

/// LockWindowController — full-screen texture background, password field and
/// optional Touch ID (fast_unlock_setting).
struct LockWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var password = ""
    @State private var error = ""
    @State private var shake = false

    var body: some View {
        ZStack {
            LockTextures.gradient(for: settings.lockTexture)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "lock.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(textStyle)
                Text(L10n.tBranded("app_title"))
                    .font(.title2.bold())
                    .foregroundStyle(textStyle)
                Text("\(L10n.t("database_title")): \(ctx.databaseName)")
                    .font(.callout)
                    .foregroundStyle(textStyle.opacity(0.8))

                SecureField(L10n.t("enter_password_prompt"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(unlock)

                if !error.isEmpty {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button(L10n.t("unlock_button", fallback: "解锁"), action: unlock)
                        .buttonStyle(.borderedProminent)
                    if ctx.touchIDAvailable && settings.fastUnlock {
                        Button {
                            ctx.unlockWithTouchID()
                        } label: {
                            Label(L10n.t("touch_id_button"), systemImage: "touchid")
                        }
                    }
                }

                if ctx.dbsInfo().count > 1 {
                    Button(L10n.t("select_database_title")) {
                        ctx.activeSheet = .selectDatabase
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(textStyle)
                }

                Spacer()
                Text("© 2026 UPasswords")
                    .font(.caption2)
                    .foregroundStyle(textStyle.opacity(0.6))
                Text(L10n.t("password_restore_warning"))
                    .font(.caption2)
                    .foregroundStyle(textStyle.opacity(0.6))
                    .frame(maxWidth: 380)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
            .offset(x: shake ? -8 : 0)
            .animation(.default.repeatCount(3, autoreverses: true), value: shake)
        }
        .frame(width: 500, height: 350)
        .preferredColorScheme(nil)
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
        let v = bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        return v == key ? fallback : v
    }
}
