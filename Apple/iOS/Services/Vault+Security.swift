import Foundation

import UPasswordsCore
import UPasswordsNetworking

// MARK: - iOS 自动泄露检查:解锁后按周期静默跑一次 HIBP(与 macOS 同语义)

extension Vault {
    /// 一天的秒数(自动检查到期换算)。
    private static let secondsPerDay: TimeInterval = 86_400

    /// 解锁后调用:开启自动检查且距上次检查超过设定天数时,静默补一次全量检查。
    func maybeRunAutoBreachCheck() {
        guard autoBreachCheckEnabled else { return }
        let days = max(autoBreachCheckDays, 1)
        let elapsed = Date().timeIntervalSince1970 - (lastBreachCheck?.timeIntervalSince1970 ?? 0)
        guard elapsed > TimeInterval(days) * Self.secondsPerDay else {
            Log.debug("security", "ios auto breach check not due (elapsed \(Int(elapsed))s)")
            return
        }
        Log.info("security", "ios auto breach check due (interval \(days)d)")
        Task { await runSilentBreachCheck() }
    }

    /// 导入/云端恢复后补一次静默全量检查:批量新增的条目不走逐条检查,
    /// 在此兜底让导入的已泄露密码立即被标记。
    func scheduleSilentBreachCheck() {
        Log.info("security", "ios silent breach check scheduled (post import)")
        Task { [weak self] in await self?.runSilentBreachCheck() }
    }

    /// 静默全量检查:命中才提示,失败不打扰;手动检查与自动周期共用防重入标志。
    func runSilentBreachCheck() async {
        guard !breachCheckInFlight else {
            Log.debug("security", "ios breach check already in flight, skipped")
            return
        }
        breachCheckInFlight = true
        defer { breachCheckInFlight = false }
        let passwords = Set(activeCards.flatMap { c in
            c.fields.filter { $0.type.needsScoring && !$0.value.isEmpty }.map(\.value)
        })
        let result = await CompromisedService.check(passwords: passwords)
        guard !result.offline else {
            Log.warn("security", "ios silent breach check offline — skipped, not recorded as clean")
            return
        }
        CompromisedService.recordBreached(result.compromisedPasswords)
        persistBreachCheckTime()
        objectWillChange.send()
        guard !result.compromisedPasswords.isEmpty else {
            Log.info("security", "ios silent breach check clean")
            return
        }
        Log.warn("security", "ios silent breach check found \(result.compromisedPasswords.count) breached password(s)")
        showToast(String(format: L10n.t("ios_breach_found_fmt"), result.compromisedPasswords.count))
    }
}
