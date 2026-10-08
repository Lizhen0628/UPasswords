import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - WebDAV 服务器配置(设置 → 云同步 → WebDAV 设置)

struct WebDavConfigSheet: View {
    @EnvironmentObject var vault: Vault

    @State private var testing = false
    @State private var testError: String? = nil

    var body: some View {
        Form {
            Section {
                Toggle("HTTPS", isOn: $vault.webdav.useHTTPS)
                TextField(L10n.t("host_prompt"), text: $vault.webdav.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("port_prompt"), value: $vault.webdav.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField(L10n.t("local_path_prompt"), text: $vault.webdav.path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("user_name_prompt"), text: $vault.webdav.user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.t("password_prompt"), text: $vault.webdav.password)
            } header: {
                Text(L10n.t("webdav_cloud"))
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: 8) {
                        if testing {
                            ProgressView()
                        }
                        Text(L10n.t("test_connection_button"))
                    }
                }
                .disabled(testing || vault.webdav.host.isEmpty)
                if let testError {
                    Text(testError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L10n.t("ios_webdav_config_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 连通性测试:成功 toast,失败原因就地展示(服务器/端口/账号错误最常见)。
    private func testConnection() async {
        testing = true
        testError = nil
        defer { testing = false }
        let driver = WebDavDriver(settings: vault.webdav, databaseName: vault.databaseName)
        do {
            try await driver.testConnection()
            vault.showToast(L10n.t("ios_test_ok_message"))
            Log.info("sync", "ios webdav test ok host=\(vault.webdav.host)")
        } catch {
            testError = error.localizedDescription
            Log.warn("sync", "ios webdav test failed: \(error)")
        }
    }
}
