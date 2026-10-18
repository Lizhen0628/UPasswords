import SwiftUI

import UPasswordsCore

@main
struct UPasswordsApp: App {
    @StateObject private var vault = Vault.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vault)
                .tint(Brand.accent)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background: vault.didEnterBackground()
                    case .active: vault.didBecomeActive()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var vault: Vault
    // UI 测试钩子(UPW_UITEST_MANAGE 环境变量):直接落到设置 Tab
    @State private var selectedTab = ProcessInfo.processInfo.environment["UPW_UITEST_MANAGE"] == "1" ? 2 : 0

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            if vault.locked {
                LockScreen()
                    .transition(.opacity)
            } else {
                MainTabView(selectedTab: $selectedTab)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vault.locked)
        .overlay(alignment: .bottom) { toastOverlay }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = vault.toast {
            Text(toast)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.fg)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Brand.elev, in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: vault.toast)
        }
    }
}

struct MainTabView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var vault: Vault
    @State private var showAdoptPrompt = false
    @State private var adoptPassword = ""
    @State private var adoptFailed = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(selectedTab: $selectedTab) }
                .tabItem { Label(L10n.t("ios_tab_passwords"), systemImage: "key.fill") }
                .tag(0)
            NavigationStack { SecurityView() }
                .tabItem { Label(L10n.t("ios_tab_security"), systemImage: "shield.lefthalf.filled") }
                .tag(1)
            NavigationStack { SettingsView() }
                .tabItem { Label(L10n.t("ios_tab_settings"), systemImage: "gearshape") }
                .tag(2)
        }
        // 远端被「其他设备改后的新主密码」重加密:主动弹窗引导接管(边沿触发,
        // 同一事件只弹一次;修复或成功后标志清除)
        .onChange(of: vault.syncRemoteUnreadable) { _, unreadable in
            if unreadable {
                Log.info("sync", "ios adopt password prompt shown (unreadable remote)")
                adoptPassword = ""
                adoptFailed = false
                showAdoptPrompt = true
            }
        }
        .alert(L10n.t("ios_sync_adopt_password_title"), isPresented: $showAdoptPrompt) {
            SecureField("", text: $adoptPassword)
            Button(L10n.t("unlock_button")) {
                let pw = adoptPassword
                Task {
                    let result = await vault.adoptRemotePassword(pw)
                    if result == .wrongPassword {
                        adoptFailed = true
                        try? await Task.sleep(for: .milliseconds(300))
                        showAdoptPrompt = true
                    }
                }
            }
            .disabled(adoptPassword.isEmpty)
            // 局面反转逃生口:本机才是改密方(云端还是旧密码)时,以本机覆盖云端
            Button(L10n.t("ios_sync_overwrite_cloud_button"), role: .destructive) {
                Log.info("sync", "ios adopt prompt → user chose overwrite with local")
                Task { await vault.overwriteUnreadableRemote() }
            }
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: {
            Text(adoptFailed ? L10n.t("sync_adopt_failed_hint")
                 : L10n.t("ios_sync_adopt_password_message"))
        }
    }
}
