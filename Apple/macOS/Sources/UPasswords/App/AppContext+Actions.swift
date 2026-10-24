import Foundation
import UPasswordsCore
import UPasswordsPersistence
import UPasswordsNetworking

/// 卡片与标签变更入口、初始化清单、历史与数据库信息。
extension AppContext {

    // MARK: - 卡片变更

    /// 按 UUID 新增或替换卡片，记录旧字段历史并安排延迟保存。
    ///
    /// - Parameter card: 编辑完成的卡片值副本；本方法刷新修改时间并选中该卡。
    func upsertCard(_ card: Card) {
        var c = card
        c.modified = Date().millis
        let existed = database.cards.contains { $0.id == c.id }
        Log.info("ui", "upsertCard id=\(c.id) title.len=\(c.title.count) new=\(!existed)")
        if let i = database.cards.firstIndex(where: { $0.id == c.id }) {
            // keep old values in field history
            for (j, f) in c.fields.enumerated() {
                if let old = database.cards[i].fields.first(where: { $0.name == f.name && $0.type == f.type }) {
                    c.fields[j].putHistoryValue(old.value, time: old.modifiedOr(c.modified))
                }
            }
            checkChangedPasswords(on: c, against: database.cards[i])
            database.cards[i] = c
        } else {
            checkChangedPasswords(on: c, against: nil)
            database.cards.append(c)
        }
        selectedCardId = c.id
        saveDebounced()
        scheduleIconFetchAfterSave(cardId: c.id)
    }

    /// 保存/修改卡片时,对新增或变更过的密码做泄露检查。本地清单已知的
    /// 泄露密码立即警告(不再发起查询);其余走在线检查(k-匿名,只上传
    /// SHA-1 前 5 位),命中提示并记入本地动态清单。离线时静默跳过在线部分。
    private func checkChangedPasswords(on newCard: Card, against oldCard: Card?) {
        let oldValues = Set(oldCard?.fields.filter { $0.type == .password }.map(\.value) ?? [])
        let values = Set(newCard.fields
            .filter { $0.type == .password && !$0.value.isEmpty }
            .map(\.value)
            .filter { !oldValues.contains($0) })
        guard !values.isEmpty else { return }
        let knownBreached = values.filter { CompromisedService.isLocallyBreached($0) }
        let toCheck = values.subtracting(knownBreached)
        let cardId = newCard.id
        let titleLen = newCard.title.count
        Task { [weak self] in
            guard let self else { return }
            if !knownBreached.isEmpty {
                objectWillChange.send()
                Log.warn("security", "saved password matches local breach list cardId=\(cardId) title.len=\(titleLen) count=\(knownBreached.count)")
                AppToast.shared.show(L10n.t("password_breached_warning"))
            }
            guard !toCheck.isEmpty else { return }
            let startedAt = Date()
            let result = await CompromisedService.check(passwords: toCheck, demo: false)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard !result.offline else {
                Log.info("security", "save-time breach check offline (hibp unreachable), skipped \(toCheck.count) password(s) cardId=\(cardId) ms=\(ms)")
                return
            }
            if result.compromisedPasswords.isEmpty {
                Log.info("security", "save-time breach check: \(toCheck.count) password(s) clean cardId=\(cardId) ms=\(ms)")
                if knownBreached.isEmpty {
                    AppToast.shared.show(L10n.t("password_not_breached_message"))
                }
                return
            }
            CompromisedService.recordBreached(result.compromisedPasswords)
            objectWillChange.send()
            Log.warn("security", "saved password is breached cardId=\(cardId) title.len=\(titleLen) count=\(result.compromisedPasswords.count) ms=\(ms)")
            AppToast.shared.show(L10n.t("password_breached_warning"))
        }
    }

    /// 将卡片标记为回收站项，刷新修改时间并安排保存。
    ///
    /// - Parameter id: 卡片 UUID；找不到时记录并返回。
    func trashCard(_ id: UUID) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "trashCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "trashCard id=\(id)")
        database.cards[i].trashed = true
        database.cards[i].modified = Date().millis
        if selectedCardId == id { selectedCardId = nil }
        saveDebounced()
    }

    /// 从本地值集合永久移除卡片，并安排保存供同步差分收集删除。
    ///
    /// - Parameter id: 被删除卡片的稳定身份。
    func deleteCardPermanently(_ id: UUID) {
        Log.info("ui", "deleteCardPermanently id=\(id)")
        database.deleteCardPermanently(id: id)
        if selectedCardId == id { selectedCardId = nil }
        saveDebounced()
    }

    /// 取消回收站和归档标志，刷新修改时间并安排保存。
    ///
    /// - Parameter id: 卡片 UUID。
    func restoreCard(_ id: UUID) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "restoreCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "restoreCard id=\(id)")
        database.cards[i].trashed = false
        database.cards[i].archived = false
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    /// 设置归档标志并安排保存，不永久删除卡片。
    ///
    /// - Parameter id: 卡片 UUID。
    func archiveCard(_ id: UUID) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "archiveCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "archiveCard id=\(id)")
        database.cards[i].archived = true
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    /// 取消归档标志并安排保存。
    ///
    /// - Parameter id: 卡片 UUID。
    func unarchiveCard(_ id: UUID) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "unarchiveCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "unarchiveCard id=\(id)")
        database.cards[i].archived = false
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    /// 切换收藏标志并安排保存。
    ///
    /// - Parameter id: 卡片 UUID。
    func toggleFavorite(_ id: UUID) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "toggleFavorite id=\(id) skipped: card not found")
            return
        }
        database.cards[i].favorite.toggle()
        Log.info("ui", "toggleFavorite id=\(id) favorite=\(database.cards[i].favorite)")
        saveDebounced()
    }

    /// Sets the card-level `autofill="on|off"` XML attribute.
    func setCardAutofill(_ id: UUID, on: Bool) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "setCardAutofill id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "setCardAutofill id=\(id) on=\(on)")
        database.cards[i].autofillEnabled = on
        saveDebounced()
    }

    /// 复制完整卡片，分配新 UUID 与时间，取消收藏并安排保存。
    ///
    /// - Parameter id: 来源卡片 UUID；字段值和附件会随值副本保留。
    func duplicateCard(_ id: UUID) {
        guard let card = database.card(id: id) else {
            Log.warn("ui", "duplicateCard id=\(id) skipped: card not found")
            return
        }
        var copy = card
        copy.id = UUID()
        copy.title = card.title
        copy.created = Date().millis
        copy.modified = copy.created
        copy.favorite = false
        database.cards.append(copy)
        selectedCardId = copy.id
        Log.info("ui", "duplicateCard id=\(id) → \(copy.id)")
        saveDebounced()
    }

    /// 永久移除所有回收站卡片，并安排保存。
    func emptyTrash() {
        let ids = database.cards.filter(\.trashed).map(\.id)
        Log.info("ui", "emptyTrash count=\(ids.count)")
        for id in ids { database.deleteCardPermanently(id: id) }
        saveDebounced()
    }

    // MARK: - Label CRUD

    /// 创建具有新 UUID 和修改时间的标签并安排保存。
    ///
    /// - Parameters:
    ///   - name: 标签展示名。
    ///   - color: 可选颜色词条。
    func addLabel(name: String, color: String?) {
        let id = UUID()
        database.labels.append(CardLabel(id: id, name: name, color: color, timeStamp: Date().millis))
        Log.info("ui", "addLabel id=\(id) name.len=\(name.count)")
        saveDebounced()
    }

    /// 修改标签名与修改时间，关联卡片继续使用同一 UUID。
    ///
    /// - Parameters:
    ///   - id: 标签 UUID。
    ///   - name: 新展示名。
    func renameCardLabel(id: UUID, to name: String) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "renameCardLabel id=\(id) skipped: label not found")
            return
        }
        Log.info("ui", "renameCardLabel id=\(id) name.len=\(name.count)")
        database.labels[i].name = name
        database.labels[i].timeStamp = Date().millis
        saveDebounced()
    }

    /// 更新指定标签的颜色与修改时间并安排保存。
    ///
    /// - Parameters:
    ///   - id: 标签 UUID。
    ///   - color: 颜色词条，nil 恢复默认。
    func setLabelColor(id: UUID, color: String?) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "setLabelColor id=\(id) skipped: label not found")
            return
        }
        Log.info("ui", "setLabelColor id=\(id)")
        database.labels[i].color = color
        saveDebounced()
    }

    /// 切换标签置顶状态并安排保存。
    ///
    /// - Parameter id: 标签 UUID。
    func toggleLabelPinned(id: UUID) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "toggleLabelPinned id=\(id) skipped: label not found")
            return
        }
        database.labels[i].pinToTop.toggle()
        Log.info("ui", "toggleLabelPinned id=\(id) pinned=\(database.labels[i].pinToTop)")
        saveDebounced()
    }

    /// 删除标签及卡片内的对应 UUID 关联，安排保存。
    ///
    /// - Parameter id: 标签 UUID。
    func deleteCardLabel(id: UUID) {
        Log.info("ui", "deleteCardLabel id=\(id)")
        database.deleteLabelPermanently(id: id)
        for i in database.cards.indices {
            database.cards[i].labelIds.removeAll { $0 == id }
        }
        if case .label(id) = selection { selection = .special(.allCards) }
        saveDebounced()
    }

    /// Sets the labels attached to a card.
    func setLabels(cardId: UUID, labelIds: [UUID]) {
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else {
            Log.warn("ui", "setLabels cardId=\(cardId) skipped: card not found")
            return
        }
        Log.info("ui", "setLabels cardId=\(cardId) labels=\(labelIds.count)")
        database.cards[i].labelIds = labelIds
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    /// Creates a label on the fly and assigns it to the card.
    func addLabelAndAssign(name: String, color: String?, to cardId: UUID) {
        let id = UUID()
        database.labels.append(CardLabel(id: id, name: name, color: color, timeStamp: Date().millis))
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else {
            Log.warn("ui", "addLabelAndAssign cardId=\(cardId) skipped: card not found (label id=\(id) kept)")
            return
        }
        Log.info("ui", "addLabelAndAssign cardId=\(cardId) labelId=\(id) name.len=\(name.count)")
        database.cards[i].labelIds.append(id)
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    // MARK: - Setup plan

    /// 查询初始化任务是否完成。
    ///
    /// - Parameter task: 初始化任务。
    /// - Returns: 对应的持久化完成标志。
    func setupTaskDone(_ task: SetupPlanTask) -> Bool {
        UserDefaults.standard.bool(forKey: "setup.done.\(task.rawValue)")
    }
    /// 记录初始化任务已完成。
    ///
    /// - Parameter task: 初始化任务。
    func markSetupTaskDone(_ task: SetupPlanTask) {
        UserDefaults.standard.set(true, forKey: "setup.done.\(task.rawValue)")
        objectWillChange.send()
    }
    /// 条件满足时记录初始化任务完成。
    ///
    /// - Parameters:
    ///   - task: 初始化任务。
    ///   - cond: 当前配置是否已满足任务要求。
    func markSetupTaskDoneIf(_ task: SetupPlanTask, when cond: Bool) {
        if cond { markSetupTaskDone(task) }
    }
    var setupCompletedCount: Int { SetupPlanTask.allCases.filter(setupTaskDone).count }

    // MARK: - Info

    /// 返回按库名排序的本地库文件描述。
    ///
    /// - Returns: 不包含已解密内容的库清单。
    func dbsInfo() -> [DatabaseFile] { store.list() }

    var allHistoryEntries: [(card: Card, field: Field, entry: HistoryEntry)] {
        var out: [(card: Card, field: Field, entry: HistoryEntry)] = []
        for c in database.cards where !c.template {
            for f in c.fields {
                for e in f.history { out.append((card: c, field: f, entry: e)) }
            }
        }
        return out.sorted { l, r in l.entry.time > r.entry.time }
    }
}
