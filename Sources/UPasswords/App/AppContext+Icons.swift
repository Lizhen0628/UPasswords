import Foundation

/// 网站/内置品牌图标抓取编排（AppContext 扩展）:
/// - 保存卡片 / 右键开启「使用网站图标」→ 后台抓取站点 favicon;
/// - 解锁后 2.5s 串行补抓存量卡片缺失的图标（间隔 300ms,锁定即停）;
/// - 抓取失败时用内置品牌图标（BrandIcons）兜底;两者都没有则保留默认符号。
/// 结果写回卡片的 iconData/iconSource 并 saveDebounced,随加密数据库持久化。
extension AppContext {

    // MARK: - 触发入口

    /// upsertCard 后调用:卡片有网址、且没有用户自定义图标时后台抓取。
    func scheduleIconFetchAfterSave(cardId: Int) {
        guard let card = database.card(id: cardId) else { return }
        guard !card.website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard card.iconData == nil, card.iconSource == nil || card.iconIsFromWebsite else { return }
        Task { [weak self] in await self?.fetchWebsiteIcon(cardId: cardId, force: false) }
    }

    /// 用户动作（图标选择器「获取网站图标」/右键开启网站图标）:立即抓取,
    /// 不受会话级防抖限制,但不覆盖用户上传/URL 图标。
    func fetchWebsiteIconNow(cardId: Int) {
        Task { [weak self] in await self?.fetchWebsiteIcon(cardId: cardId, force: true) }
    }

    /// 右键「使用网站图标」开关;开启时顺带触发一次抓取。
    func toggleUseWebsiteIcon(cardId: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else {
            Log.warn("ui", "toggleUseWebsiteIcon cardId=\(cardId) skipped: card not found")
            return
        }
        database.cards[i].useWebsiteIcon.toggle()
        let enabled = database.cards[i].useWebsiteIcon
        Log.info("ui", "toggleUseWebsiteIcon cardId=\(cardId) enabled=\(enabled)")
        saveDebounced()
        if enabled { fetchWebsiteIconNow(cardId: cardId) }
    }

    /// 解锁后补抓:只处理「有网址、无图标数据、来源为空或 website」的活动卡片。
    func scheduleIconBackfill() {
        guard iconBackfillTask == nil else { return }
        let targets = database.activeCards
            .filter { !$0.website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { $0.iconData == nil && ($0.iconSource == nil || $0.iconIsFromWebsite) }
            .filter { !iconFetchAttempted.contains($0.id) }
            .map(\.id)
        guard !targets.isEmpty else { return }
        Log.info("icons", "backfill scheduled count=\(targets.count)")
        iconBackfillTask = Task { [weak self] in
            // Task 从 @MainActor 上下文创建,继承主actor隔离;网络等待在 IconService 内部
            try? await Task.sleep(for: .seconds(2.5))
            for cardId in targets {
                guard let self, self.phase == .unlocked else { break }
                await self.fetchWebsiteIcon(cardId: cardId, force: false)
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.iconBackfillTask = nil
            Log.info("icons", "backfill finished")
        }
    }

    // MARK: - 抓取落库

    /// 抓取站点图标并写回卡片:
    /// 成功 → iconData + iconSource=website;
    /// 失败 → 域名/标题匹配内置品牌图标时 iconSource=builtin:<key>;
    /// 都失败 → 保留默认符号（只记会话防抖,不重试至下次解锁）。
    ///
    /// - Parameter force: 用户显式触发时 true,绕过会话防抖;仍不覆盖上传/URL 图标。
    private func fetchWebsiteIcon(cardId: Int, force: Bool) async {
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else { return }
        let card = database.cards[i]
        guard let host = IconService.host(fromWebsite: card.website) else {
            Log.debug("icons", "fetch skipped cardId=\(cardId): no usable host")
            return
        }
        if force {
            guard !card.iconIsUserExplicit else {
                Log.info("icons", "fetch skipped cardId=\(cardId): user icon kept")
                return
            }
        } else {
            guard card.iconData == nil, card.iconSource == nil || card.iconIsFromWebsite,
                  !iconFetchAttempted.contains(cardId) else { return }
        }
        iconFetchAttempted.insert(cardId)
        let started = Date()
        Log.info("icons", "fetch start cardId=\(cardId) host=\(host) force=\(force)")

        var fetched: Data? = nil
        do {
            fetched = try await IconService.fetchFavicon(host: host)
        } catch {
            Log.warn("icons", "fetch failed cardId=\(cardId) host=\(host): \(String(describing: error))")
        }

        // 等待网络期间卡片可能被删/库被锁
        guard phase == .unlocked, let j = database.cards.firstIndex(where: { $0.id == cardId }) else {
            Log.debug("icons", "fetch dropped cardId=\(cardId): card gone or locked")
            return
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let data = fetched {
            database.cards[j].iconData = data
            database.cards[j].iconSource = IconService.sourceWebsite
            database.cards[j].useWebsiteIcon = true
            database.cards[j].modified = Date().millis
            Log.info("icons", "fetch applied cardId=\(cardId) host=\(host) bytes=\(data.count) ms=\(ms)")
            saveDebounced()
        } else if let entry = BrandIcons.match(host: host, title: card.title),
                  force || database.cards[j].iconSource == nil {
            database.cards[j].iconSource = IconService.sourceBuiltinPrefix + entry.key
            database.cards[j].iconData = nil
            database.cards[j].useWebsiteIcon = true
            database.cards[j].modified = Date().millis
            Log.info("icons", "brand fallback cardId=\(cardId) key=\(entry.key) ms=\(ms)")
            saveDebounced()
        } else {
            Log.info("icons", "no icon resolved cardId=\(cardId) host=\(host) (default symbol kept) ms=\(ms)")
        }
    }
}
