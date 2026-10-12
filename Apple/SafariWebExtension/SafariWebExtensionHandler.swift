import Foundation
import SafariServices

import UPasswordsCore

/// Safari Web Extension 的原生消息桥。
/// 前端经 browser.runtime.sendNativeMessage 发来的请求(SFExtensionMessageKey)
/// 在此分发:ping(状态)/ unlock(主密码解密库,内存缓存) / query(host 匹配候选)。
///
/// 库文件解析:优先 App Group 容器里主 App 推送的加密快照(沙盒分发形态),
/// 回退主 App 的 Application Support 活库文件(未沙盒的本地构建)。
/// 隐私红线:日志只记操作/host/数量,主密码与字段值绝不落盘、不进日志;
/// 解密结果只在 appex 进程内存中存活,进程回收即失效。
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// 与 iOS 同名的共享容器组(macOS 主 App 推送快照的目标)。
    private static let appGroup = "group.com.upasswords.shared"

    /// 诊断日志:直接落 App Group(bridge.log),不经 AppLog——appex 沙盒里
    /// Application Support 可能不可写/不可见,App Group 是双方共用的确定路径。
    /// 只记操作与结果分支,不含密码与字段值。
    private static func diag(_ line: String) {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return
        }
        let url = group.appendingPathComponent("Safari/bridge.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// 解锁后缓存的活动条目(剔除回收站/归档/模板)。
    private static var cachedCards: [Card]? = nil
    private static var cachedVaultName: String? = nil
    /// 缓存写入时间:空闲超过 unlockTTL 即自动锁定(与主 App 自动锁定对齐,
    /// 原生桥常驻进程不受主 App 锁定事件管辖,必须自带时效)。
    private static var cachedAt: Date? = nil
    /// 解锁失败退避:指数递增,封顶 15 分钟——扩展弹窗不得成为
    /// 绕过主 App 自毁/锁定体系的爆破入口。
    private static var failedUnlocks = 0
    private static var lockedUntil = Date.distantPast
    private static let unlockTTL: TimeInterval = 5 * 60
    private static let maxBackoff: TimeInterval = 15 * 60

    /// 空闲超时自动锁定:ping/query/unlock 进入时都先过这道闸。
    private static func lockIfIdle() {
        guard let at = cachedAt, Date().timeIntervalSince(at) > unlockTTL else { return }
        cachedCards = nil
        cachedVaultName = nil
        cachedAt = nil
        diag("auto-lock after idle")
    }

    private static func clearCache() {
        cachedCards = nil
        cachedVaultName = nil
        cachedAt = nil
    }

    private static func registerUnlockFailure() {
        failedUnlocks += 1
        let backoff = min(30 * pow(2, Double(failedUnlocks - 1)), maxBackoff)
        lockedUntil = Date().addingTimeInterval(backoff)
        diag("unlock failed count=\(failedUnlocks) backoff=\(Int(backoff))s")
    }

    func beginRequest(with context: NSExtensionContext) {
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let message = items.first?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let type = (message?["type"] as? String) ?? ""
        Log.info("chrome", "safari native message: \(type)")
        Self.diag("msg \(type)")
        Self.lockIfIdle()
        let response: [String: Any]
        switch type {
        case "ping": response = Self.handlePing()
        case "unlock": response = Self.handleUnlock(message)
        case "query": response = Self.handleQuery(message)
        case "lock": response = Self.handleLock()
        default: response = ["type": "error", "message": "unknown message type"]
        }
        Self.diag("resp \(type) -> \(response["type"] as? String ?? "?") ok=\(response["ok"] as? Bool ?? false) reason=\(response["reason"] as? String ?? "-")")
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    // MARK: - 消息处理

    /// 握手 + 状态:库是否存在、是否已在扩展侧解锁。
    private static func handlePing() -> [String: Any] {
        let vault = vaultFile()
        diag("ping vault=\(vault?.name ?? "nil") unlocked=\(cachedCards != nil)")
        return [
            "type": "pong",
            "vault": vault != nil,
            "unlocked": cachedCards != nil,
            "name": cachedVaultName ?? vault?.name ?? "",
        ]
    }

    /// 解锁:主密码解密库容器,活动条目缓存进内存。
    /// 失败原因显式区分(noVault / noEnvelope / badPassword),前端据此给出
    /// 准确提示——一律报"密码错误"会把快照缺失/信封缺失误导成密码问题。
    private static func handleUnlock(_ message: [String: Any]?) -> [String: Any] {
        guard let password = message?["password"] as? String, !password.isEmpty else {
            return ["type": "error", "message": "missing password"]
        }
        if Date() < Self.lockedUntil {
            diag("unlock throttled")
            return ["type": "unlocked", "ok": false, "reason": "throttled"]
        }
        guard let vault = vaultFile() else {
            Log.warn("chrome", "safari unlock: no vault file accessible (snapshot and local db missing)")
            diag("unlock no vault accessible")
            return ["type": "noVault"]
        }
        diag("unlock vault=\(vault.name) path=\(vault.url.lastPathComponent)")
        do {
            let data = try Data(contentsOf: vault.url)
            // v2:主密码解信封(同名 .upwkey)拿库密钥再解本体
            guard DatabaseCipher.isV2Container(data) else {
                Log.warn("chrome", "safari unlock \"\(vault.name)\" rejected: not a v2 container")
                return ["type": "unlocked", "ok": false, "reason": "notV2"]
            }
            let keyURL = vault.url.deletingPathExtension().appendingPathExtension("upwkey")
            guard FileManager.default.fileExists(atPath: keyURL.path) else {
                Log.warn("chrome", "safari unlock \"\(vault.name)\": envelope file missing (snapshot incomplete)")
                return ["type": "unlocked", "ok": false, "reason": "noEnvelope"]
            }
            do {
                let envelope = try Data(contentsOf: keyURL)
                let vek = try DatabaseCipher.unwrapVaultKey(envelope, password: password)
                let db = try PasswordDatabase.parse(DatabaseCipher.decryptBody(data, vaultKey: vek))
                cachedCards = db.cards.filter { !$0.trashed && !$0.archived && !$0.template }
                cachedVaultName = vault.name
                cachedAt = Date()
                failedUnlocks = 0
                Log.info("chrome", "safari vault \"\(vault.name)\" unlocked: \(cachedCards?.count ?? 0) cards")
                return ["type": "unlocked", "ok": true, "count": cachedCards?.count ?? 0]
            } catch {
                Log.warn("chrome", "safari unlock \"\(vault.name)\" rejected (wrong password or corrupt container)")
                Self.registerUnlockFailure()
                return ["type": "unlocked", "ok": false, "reason": "badPassword"]
            }
        } catch {
            Log.warn("chrome", "safari unlock \"\(vault.name)\" failed reading container: \(error)")
            return ["type": "unlocked", "ok": false, "reason": "badPassword"]
        }
    }

    /// 主动锁定:清空内存缓存(前端在锁定按钮/空闲时调用)。
    private static func handleLock() -> [String: Any] {
        clearCache()
        diag("locked by message")
        return ["type": "locked", "ok": true]
    }

    /// 查询:返回与页面 host 匹配的填充候选(含凭据,契约允许)。
    private static func handleQuery(_ message: [String: Any]?) -> [String: Any] {
        guard let cards = cachedCards, !cards.isEmpty else {
            // 库文件读不到时显式声明 noVault:前端据此提示推快照,而不是
            // 误报"locked"诱导用户输密码(输了也必败,且被误读为密码错误)
            if vaultFile() == nil {
                Log.warn("chrome", "safari query: no vault file accessible (group snapshot and local db missing)")
                return ["type": "noVault"]
            }
            Log.debug("chrome", "safari query while locked")
            return ["type": "locked"]
        }
        let pageHost = canonicalize((message?["host"] as? String) ?? "")
        var candidates: [[String: Any]] = []
        for card in cards {
            let itemHost = canonicalize(hostString(of: card))
            guard hostMatches(pageHost: pageHost, itemHost: itemHost) else { continue }
            var username = ""
            var password = ""
            var fields: [[String: Any]] = []
            for f in card.fields where f.hasValue {
                if username.isEmpty, f.type == .login || f.type == .email { username = f.value }
                if password.isEmpty, f.type == .password { password = f.value }
                fields.append([
                    "name": f.name,
                    "type": f.type.rawValue,
                    "value": f.value,
                    "autofill": f.autofill.rawValue,
                ])
            }
            candidates.append([
                "item": [
                    "id": card.id,
                    "title": card.title,
                    "symbol": card.symbol as Any,
                    "fields": fields,
                    "host": itemHost,
                ],
                "username": username,
                "password": password,
            ])
        }
        Log.info("chrome", "safari query host=\(pageHost): \(candidates.count) candidate(s)")
        return ["type": "items", "candidates": candidates]
    }

    // MARK: - 库文件解析

    /// 定位当前库容器:优先 App Group 快照目录(current 标记指向活跃库),
    /// 回退 Application Support 活库目录(取最近修改者)。
    private static func vaultFile() -> (url: URL, name: String)? {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let dir = group.appendingPathComponent("Safari", isDirectory: true)
            let marker = dir.appendingPathComponent("current")
            if let name = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                let url = dir.appendingPathComponent("\(name).upw")
                if fm.fileExists(atPath: url.path) { return (url, name) }
            }
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               let first = files.filter({ $0.pathExtension == "upw" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                return (first, first.deletingPathExtension().lastPathComponent)
            }
        }
        // FileManager 系统目录必然存在(逻辑保证)
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacy = base.appendingPathComponent("UPasswords/Databases", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let latest = files.filter { $0.pathExtension == "upw" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        guard let latest else { return nil }
        return (latest, latest.deletingPathExtension().lastPathComponent)
    }

    // MARK: - host 匹配(镜像 WebExtensions/shared domain.ts 语义)

    /// 技术性前缀(www/m/login 等)剥离,镜像 TS canonicalizeHost。
    private static func canonicalize(_ host: String) -> String {
        let wired: Set<String> = ["www", "m", "mobile", "account", "accounts", "login", "signin", "auth"]
        var parts = host.lowercased().split(separator: ".").map(String.init)
        while parts.count > 2, let first = parts.first, wired.contains(first) {
            parts.removeFirst()
        }
        return parts.joined(separator: ".")
    }

    /// 卡片站点 host:网址字段可能是裸域或完整 URL。
    private static func hostString(of card: Card) -> String {
        let raw = card.website.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "" }
        if let url = URL(string: raw), let host = url.host { return host }
        if let url = URL(string: "https://\(raw)"), let host = url.host { return host }
        return raw
    }

    /// 标签级后缀匹配(任一方向),镜像 TS hostMatches。
    private static func hostMatches(pageHost: String, itemHost: String) -> Bool {
        guard !pageHost.isEmpty, !itemHost.isEmpty else { return false }
        return pageHost == itemHost
            || pageHost.hasSuffix(".\(itemHost)")
            || itemHost.hasSuffix(".\(pageHost)")
    }
}
