import Foundation

/// 泄露密码检查(HIBP k-匿名):手动弹窗、自动周期检查、保存时单点检查共用。
/// 在线命中的密码会记入本地动态离线清单(CompromisedService.recordBreached),
/// 侧栏「已泄露密码」计数据此实时更新。
extension AppContext {

    /// 泄露库检查周期下限(天):防止误设过密频繁打 HIBP。
    static let minBreachCheckDays = 1

    /// 上次全量检查的 UserDefaults 键(按数据库分开记)。
    private var lastBreachCheckKey: String { "breach.last.\(databaseName)" }

    /// 上次全量在线检查时间(nil = 从未)。
    var lastBreachCheck: Date? {
        let t = UserDefaults.standard.double(forKey: lastBreachCheckKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// 常驻到期 ticker:每 60s 检查一次,距上次检查超过设定周期即静默全量检查。
    /// 不随设置变化重排(周期改动下一跳自然生效);锁屏/未启用时空转。
    func startBreachCheckTickerIfNeeded() {
        guard breachCheckTimer == nil else { return }
        breachCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.breachCheckTick() }
        }
        Log.debug("security", "breach check ticker installed")
    }

    private func breachCheckTick() {
        guard phase == .unlocked, settings.autoBreachCheckEnabled else { return }
        let days = max(settings.autoBreachCheckDays, Self.minBreachCheckDays)
        let elapsed = Date().timeIntervalSince1970 - (lastBreachCheck?.timeIntervalSince1970 ?? 0)
        guard elapsed >= Double(days) * 86400 else { return }
        Log.info("security", "auto breach check due (interval \(days)d, elapsed \(Int(elapsed))s, db=\"\(databaseName)\")")
        Task { await runSilentBreachCheck() }
    }

    /// 静默全量检查:命中才提示,失败不打扰;自动周期与导入/恢复后的补查共用。
    /// 防重入:60s ticker 不会在一次长检查未完成时重复发起。
    func runSilentBreachCheck() async {
        guard !breachCheckInFlight else {
            Log.debug("security", "breach check already in flight, skipped")
            return
        }
        breachCheckInFlight = true
        defer { breachCheckInFlight = false }
        let outcome = await checkCompromisedPasswords(online: true)
        guard !outcome.result.offline, !outcome.cards.isEmpty else { return }
        Log.warn("security", "silent breach check found \(outcome.cards.count) compromised card(s)")
        AppToast.shared.show("\(L10n.t("compromised_passwords_found_text")) \(outcome.cards.count)")
    }

    /// 导入/云端恢复完成后补一次静默全量检查:批量新增的卡片不走 upsertCard
    /// (保存时检查覆盖不到),在此统一兜底,让导入的已泄露密码立即被标记。
    func scheduleSilentBreachCheck() {
        Log.info("security", "silent breach check scheduled (post import/restore)")
        Task { [weak self] in
            guard let self else { return }
            await runSilentBreachCheck()
        }
    }

    /// 全库泄露检查(手动弹窗与自动检查共用):在线走 HIBP k-匿名(只上传
    /// SHA-1 前 5 位),离线走内嵌常见清单;在线命中的密码记入本地动态清单。
    /// 日志区分"真在线"与"网络失败后的离线回退"——后者绝不冒充干净结果。
    @discardableResult
    func checkCompromisedPasswords(online: Bool) async -> (cards: [Card], result: CompromisedService.Result) {
        let startedAt = Date()
        let passwords = Set(database.activeCards.flatMap { card in
            card.fields.filter { $0.type == .password && !$0.value.isEmpty }.map(\.value)
        })
        let result = await CompromisedService.check(passwords: passwords, demo: !online)
        if online {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastBreachCheckKey)
            if !result.compromisedPasswords.isEmpty {
                CompromisedService.recordBreached(result.compromisedPasswords)
            }
        }
        let cards = database.activeCards.filter { card in
            card.fields.contains { $0.type == .password && result.compromisedPasswords.contains($0.value) }
        }
        let mode = result.offline ? (online ? "online→offline-fallback" : "offline") : "online"
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info("security", "compromised check (\(mode)) db=\"\(databaseName)\": \(result.compromisedPasswords.count) password(s) in \(cards.count) card(s) ms=\(ms)")
        if online, !result.compromisedPasswords.isEmpty {
            // Card.compromised 依赖动态清单,命中后让侧栏立即重算
            objectWillChange.send()
        }
        return (cards, result)
    }
}
