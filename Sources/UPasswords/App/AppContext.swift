import Foundation
import SwiftUI
import Combine
import LocalAuthentication

/// Central session controller — the SwiftUI counterpart of `DatabaseManager`
/// (Services/DatabaseManager.h) plus the card-list strategies the original
/// implements through `CardListStrategy` subclasses per sidebar label.
@MainActor
final class AppContext: ObservableObject {
    enum Phase: Equatable {
        case setup        // SetupWindowController flow (first launch)
        case locked       // LockWindowController
        case unlocked     // MainWindowController
    }

    // MARK: - Published state
    @Published var phase: Phase = .setup
    @Published var database = PasswordDatabase()
    @Published var databaseName: String = ""
    @Published var selection: SidebarSelection = .special(.allCards)
    @Published var selectedCardId: Int? = nil
    @Published var searchText: String = ""
    @Published var editDraft: EditCardModel? = nil
    @Published var activeSheet: AppSheet? = nil
    @Published var syncState: SyncState = .disabled
    @Published var lastSync: Date? = nil
    @Published var lastSyncFailed: Date? = nil
    @Published var failedUnlockAttempts = 0
    @Published var lastActivity: Date = Date()

    enum SyncState: Equatable {
        case disabled, idle, syncing, error(String)
    }

    /// In-memory password, present only while unlocked.
    nonisolated(unsafe) private(set) var password: String = ""

    let settings = AppSettings.shared
    let store = DatabaseStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var autoLockTimer: Timer? = nil

    static let shared = AppContext()

    init() {
        bootstrapPhase()
        installActivityMonitor()
    }

    // MARK: - Bootstrap

    private func bootstrapPhase() {
        let dbs = store.list()
        if dbs.isEmpty {
            phase = .setup
        } else {
            phase = .locked
            databaseName = store.exists(store.mainDatabaseName)
                ? store.mainDatabaseName
                : (dbs.first?.name ?? "Main")
        }
    }

    // MARK: - Setup / lifecycle (SetupWindowController → DatabaseManager)

    func createDatabase(name: String, password: String, touchID: Bool) throws {
        try store.create(name: name, password: password)
        store.mainDatabaseName = name
        if touchID && PasswordStore.biometricAvailable() {
            PasswordStore.savePasswordForBiometric(password, databaseName: name)
        }
        try unlock(name: name, password: password)
        activeSheet = .setupPlan
    }

    func unlock(name: String, password: String) throws {
        database = try store.load(name: name, password: password)
        databaseName = name
        self.password = password
        phase = .unlocked
        lastActivity = Date() // otherwise the idle timer re-locks right after unlocking
        failedUnlockAttempts = 0
        selection = .special(.allCards)
        selectedCardId = database.activeCards.first?.id
        scheduleAutoBackupIfNeeded()
        markSetupTaskDoneIf(.cloudSync, when: settings.cloud != .none)
        markSetupTaskDoneIf(.autoBackup, when: settings.autoBackupEnabled)
        markSetupTaskDoneIf(.touchID, when: settings.fastUnlock && PasswordStore.biometricAvailable())
        announceStartupSheets()
    }

    /// WhatsNewSheetController (whats_new.json) + expiring_cards_warning prompt.
    private func announceStartupSheets() {
        let version = "1.0"
        if settings.showWhatsNewAtStartup && settings.lastWhatsNewVersion != version {
            settings.lastWhatsNewVersion = version
            activeSheet = .whatsNew
            return
        }
        if !cards(for: .special(.expiring), search: "").isEmpty {
            activeSheet = .expiredCards
        }
    }

    /// LockWindowController + LockedState.enter
    func lock() {
        guard phase == .unlocked else { return }
        password = ""
        phase = .locked
        activeSheet = nil
        editDraft = nil
    }

    var touchIDAvailable: Bool {
        PasswordStore.biometricAvailable()
    }

    /// LockedState biometric unlock: prompts Touch ID then unlocks.
    func unlockWithTouchID() {
        guard phase == .locked, settings.fastUnlock,
              let pw = PasswordStore.biometricPassword(databaseName: databaseName) else { return }
        try? unlock(name: databaseName, password: pw)
    }

    func registerFailedAttempt() {
        failedUnlockAttempts += 1
        let limit = settings.selfDestructAttempts
        if limit > 0, failedUnlockAttempts >= limit {
            eraseAllData()
        }
    }

    /// erase_data_command — removes local data (cloud copies untouched).
    func eraseAllData() {
        for db in store.list() {
            try? store.delete(name: db.name)
        }
        database = PasswordDatabase()
        databaseName = ""
        password = ""
        phase = .setup
    }

    // MARK: - Persistence

    func save() {
        guard phase == .unlocked else { return }
        do {
            try store.save(database, name: databaseName, password: password)
        } catch {
            AppToast.shared.show(error.localizedDescription)
        }
    }

    private var saveDebounce: AnyCancellable? = nil
    func saveDebounced() {
        saveDebounce?.cancel()
        saveDebounce = Just(())
            .delay(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    // MARK: - Recent (RecentModel)

    private static let recentKey = "recent.cardIds"

    var recentIds: [Int] {
        UserDefaults.standard.array(forKey: Self.recentKey) as? [Int] ?? []
    }

    func pushRecent(_ cardId: Int) {
        var ids = UserDefaults.standard.array(forKey: Self.recentKey) as? [Int] ?? []
        ids.removeAll { $0 == cardId }
        ids.insert(cardId, at: 0)
        if ids.count > 20 { ids.removeLast(ids.count - 20) }
        UserDefaults.standard.set(ids, forKey: Self.recentKey)
        objectWillChange.send()
    }

    func clearRecent() {
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
        objectWillChange.send()
    }

    // MARK: - Setup plan

    func setupTaskDone(_ task: SetupPlanTask) -> Bool {
        UserDefaults.standard.bool(forKey: "setup.done.\(task.rawValue)")
    }
    func markSetupTaskDone(_ task: SetupPlanTask) {
        UserDefaults.standard.set(true, forKey: "setup.done.\(task.rawValue)")
        objectWillChange.send()
    }
    private func markSetupTaskDoneIf(_ task: SetupPlanTask, when cond: Bool) {
        if cond { markSetupTaskDone(task) }
    }
    var setupCompletedCount: Int { SetupPlanTask.allCases.filter(setupTaskDone).count }

    // MARK: - Card list strategies (CardListStrategy)

    /// The card list for the current sidebar selection + search — mirrors the
    /// per-special-label strategies (ArchiveCardListStrategy, TrashCardListStrategy, …).
    func cards(for selection: SidebarSelection, search: String) -> [Card] {
        let searchWords = search.lowercased()
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var cards: [Card]
        switch selection {
        case .special(let sp):
            cards = strategyCards(for: sp)
        case .label(let labelId):
            cards = database.activeCards.filter { $0.labelIds.contains(labelId) && !$0.archived }
        }
        if !searchWords.isEmpty {
            cards = cards.filter { satisfiesSearch($0, words: searchWords) }
        }
        return settings.sortingValue.sort(cards, favoritesFirst: settings.favoritesAtTop)
    }

    private func strategyCards(for sp: SpecialLabel) -> [Card] {
        let active = database.activeCards
        switch sp {
        case .allCards:
            return active.filter { !$0.archived }
        case .favorites:
            return active.filter { $0.favorite && !$0.archived }
        case .recent:
            let ids = recentIds
            return ids.compactMap { id in active.first { $0.id == id } }
        case .passwords:
            return active.filter { !$0.archived && $0.fields.contains { $0.type == .password } }
        case .oneTimeCodes:
            return active.filter { !$0.archived && $0.fields.contains { $0.type == .oneTimePassword } }
        case .notes:
            return active.filter { !$0.archived && $0.hasNotes && $0.fields.allSatisfy { !$0.type.isLogin && $0.type != .password } }
        case .files:
            return active.filter { !$0.archived && $0.hasFiles }
        case .images:
            return active.filter { !$0.archived && $0.hasImages }
        case .passkeys:
            return [] // passkeys are created in the mobile version (passkeys_empty_state)
        case .creditCards:
            return active.filter { !$0.archived && $0.symbol == "credit_card" }
        case .weakPasswords:
            return active.filter { !$0.archived && $0.hasWeakPasswords }
        case .samePasswords:
            let groups = SamePasswordsService.groups(cards: active)
            let ids = Set(groups.values.flatMap { $0 })
            return active.filter { ids.contains($0.id) }
        case .compromised:
            return active.filter { !$0.archived && $0.compromised }
        case .expiring:
            return active.filter { !$0.archived && !$0.trashed && $0.isExpiring }
        case .expired:
            return active.filter { !$0.archived && !$0.trashed && $0.isExpired }
        case .archived:
            return active.filter { $0.archived }
        case .trash:
            return database.cards.filter { $0.trashed }
        case .templates:
            return database.templateCards.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// XCard.satisfiesToSearchWords:labelNames: — every word must hit title,
    /// field name/value, notes or label names; passwords optionally included.
    private func satisfiesSearch(_ card: Card, words: [String]) -> Bool {
        words.allSatisfy { containsWord(card, word: $0) }
    }

    private func containsWord(_ card: Card, word: String) -> Bool {
        if card.title.lowercased().contains(word) { return true }
        if card.notes.lowercased().contains(word) { return true }
        for f in card.fields {
            if f.name.lowercased().contains(word) { return true }
            if f.type.isSearchable {
                if !f.type.isHidden || settings.searchPasswords {
                    if f.value.lowercased().contains(word) { return true }
                } else if f.value.lowercased().contains(word) {
                    return true // hidden fields match on value but not shown in preview
                }
            }
        }
        if settings.searchByLabels {
            for lid in card.labelIds {
                if let l = database.label(id: lid), l.name.lowercased().contains(word) { return true }
            }
        }
        return false
    }

    /// XCard.previewForSearchWords — the "title — matched snippet" row preview.
    func searchPreview(for card: Card, word: String) -> String? {
        let w = word.lowercased()
        for f in card.fields where f.type.isSearchable {
            if !f.type.isHidden || settings.searchPasswords {
                if f.value.lowercased().contains(w) {
                    return "\(f.name): …\(snippet(f.value, around: w))…"
                }
            }
        }
        if card.notes.lowercased().contains(w) {
            return "…\(snippet(card.notes, around: w))…"
        }
        return nil
    }

    private func snippet(_ text: String, around w: String) -> String {
        guard let r = text.range(of: w, options: .caseInsensitive) else { return String(text.prefix(30)) }
        let start = text.index(r.lowerBound, offsetBy: -10, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    /// Sidebar badge counts (show_card_count_setting).
    func count(for selection: SidebarSelection) -> Int {
        cards(for: selection, search: "").count
    }

    // MARK: - Card CRUD (DatabaseManager actions)

    func newCardId() -> Int { database.nextItemId() }

    func instantiate(templateId: Int) -> Card {
        if let spec = Templates.spec(id: templateId) {
            return Templates.makeCard(from: spec, id: newCardId())
        }
        var c = Card(id: newCardId())
        c.created = Date().millis
        c.modified = c.created
        return c
    }

    func upsertCard(_ card: Card) {
        var c = card
        c.modified = Date().millis
        if let i = database.cards.firstIndex(where: { $0.id == c.id }) {
            // keep old values in field history
            for (j, f) in c.fields.enumerated() {
                if let old = database.cards[i].fields.first(where: { $0.name == f.name && $0.type == f.type }) {
                    c.fields[j].putHistoryValue(old.value, time: old.modifiedOr(c.modified))
                }
            }
            database.cards[i] = c
        } else {
            database.cards.append(c)
        }
        selectedCardId = c.id
        saveDebounced()
    }

    func trashCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else { return }
        database.cards[i].trashed = true
        database.cards[i].modified = Date().millis
        if selectedCardId == id { selectedCardId = nil }
        saveDebounced()
    }

    func deleteCardPermanently(_ id: Int) {
        database.deleteCardPermanently(id: id)
        if selectedCardId == id { selectedCardId = nil }
        saveDebounced()
    }

    func restoreCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else { return }
        database.cards[i].trashed = false
        database.cards[i].archived = false
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    func archiveCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else { return }
        database.cards[i].archived = true
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    func unarchiveCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else { return }
        database.cards[i].archived = false
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    func toggleFavorite(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else { return }
        database.cards[i].favorite.toggle()
        saveDebounced()
    }

    /// card-level `autofill="on|off"` XML attribute (ViewCardViewController checkbox).
    func setCardAutofill(_ id: Int, on: Bool) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else { return }
        database.cards[i].autofillEnabled = on
        saveDebounced()
    }

    func duplicateCard(_ id: Int) {
        guard let card = database.card(id: id) else { return }
        var copy = card
        copy.id = newCardId()
        copy.title = card.title
        copy.created = Date().millis
        copy.modified = copy.created
        copy.favorite = false
        database.cards.append(copy)
        selectedCardId = copy.id
        saveDebounced()
    }

    func emptyTrash() {
        let ids = database.cards.filter(\.trashed).map(\.id)
        for id in ids { database.deleteCardPermanently(id: id) }
        saveDebounced()
    }

    // MARK: - Label CRUD

    func addLabel(name: String, color: String?) {
        let id = database.nextItemId()
        database.labels.append(CardLabel(id: id, name: name, color: color, timeStamp: Date().millis))
        saveDebounced()
    }

    func renameCardLabel(id: Int, to name: String) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else { return }
        database.labels[i].name = name
        database.labels[i].timeStamp = Date().millis
        saveDebounced()
    }

    func setLabelColor(id: Int, color: String?) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else { return }
        database.labels[i].color = color
        saveDebounced()
    }

    func toggleLabelPinned(id: Int) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else { return }
        database.labels[i].pinToTop.toggle()
        saveDebounced()
    }

    func deleteCardLabel(id: Int) {
        database.labels.removeAll { $0.id == id }
        for i in database.cards.indices {
            database.cards[i].labelIds.removeAll { $0 == id }
        }
        if case .label(id) = selection { selection = .special(.allCards) }
        saveDebounced()
    }

    /// setLabels on a card (SetLabelsSheetController).
    func setLabels(cardId: Int, labelIds: [Int]) {
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else { return }
        database.cards[i].labelIds = labelIds
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    /// SetLabelsViewController "create new label on the fly".
    func addLabelAndAssign(name: String, color: String?, to cardId: Int) {
        let id = database.nextItemId()
        database.labels.append(CardLabel(id: id, name: name, color: color, timeStamp: Date().millis))
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else { return }
        database.cards[i].labelIds.append(id)
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    // MARK: - Change password (SetPasswordSheetController / changePassword:)

    func changePassword(current: String, new: String) throws {
        guard current == password else { throw DatabaseCipher.CipherError(message: L10n.t("wrong_password_error")) }
        // re-encrypt under the new password
        try store.save(database, name: databaseName, password: new)
        PasswordStore.savePassword(new, databaseName: databaseName)
        if settings.fastUnlock && PasswordStore.biometricAvailable() {
            PasswordStore.savePasswordForBiometric(new, databaseName: databaseName)
        }
        password = new
    }

    // MARK: - Info

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

    // MARK: - Backup / sync

    func backupNow() {
        save()
        do {
            try store.backup(name: databaseName, password: password)
            AppToast.shared.show(L10n.t("database_saved_message") + " " + L10n.t("backup_command"))
        } catch {
            AppToast.shared.show(error.localizedDescription)
        }
    }

    private func scheduleAutoBackupIfNeeded() {
        guard settings.autoBackupEnabled, settings.backupIntervalDays > 0 else { return }
        let last = UserDefaults.standard.double(forKey: "backup.last.\(databaseName)")
        let interval = Double(settings.backupIntervalDays) * 86400
        if Date().timeIntervalSince1970 - last >= interval {
            try? store.backup(name: databaseName, password: password)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.last.\(databaseName)")
        }
    }

    /// sync: — WebDavDriver download/merge/upload.
    func sync() async {
        guard settings.cloud == .webdav else {
            if settings.cloud == .none {
                syncState = .disabled
                AppToast.shared.show(L10n.t("sync_disabled_state"))
            } else {
                AppToast.shared.show(L10n.t("not_configured_state"))
            }
            return
        }
        syncState = .syncing
        save()
        let driver = WebDavDriver(settings: settings.webdav, databaseName: databaseName)
        do {
            try await driver.testConnection()
            let remoteData = try await driver.download()
            var local = database
            if let remoteData {
                let plain = try DatabaseCipher.decryptedData(remoteData, password: password)
                let remote = try PasswordDatabase.parse(plain)
                local.merge(with: remote)
                database = local
                save()
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            lastSync = Date()
            syncState = .idle
            AppToast.shared.show(L10n.t("last_sync_completed_prompt") + " " + DateFormatter.localizedString(from: lastSync!, dateStyle: .short, timeStyle: .short))
        } catch {
            lastSyncFailed = Date()
            syncState = .error(error.localizedDescription)
            AppToast.shared.show("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-lock (LockedState + auto_lock_setting)

    private func installActivityMonitor() {
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoLockTick() }
        }
        // Any interaction with the app (typing, clicks, scrolling) counts as
        // activity for the idle timer — not just switching the selected card.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { event in
            Task { @MainActor [weak self] in self?.touch() }
            return event
        }
        NSApplication.shared.publisher(for: \.isHidden)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                if hidden == true, self?.settings.lockInBackground == true {
                    self?.lock()
                }
            }
            .store(in: &cancellables)
    }

    private func autoLockTick() {
        guard phase == .unlocked, settings.autoLockSeconds > 0 else { return }
        if Date().timeIntervalSince(lastActivity) >= Double(settings.autoLockSeconds) {
            lock()
        }
    }

    func touch() { lastActivity = Date() }
}

extension Field {
    func modifiedOr(_ fallback: TimeInterval) -> TimeInterval { fallback }
}

/// Sheets catalog — one case per original *SheetController; associated values
/// carry targets (label id, card id, field draft…).
enum AppSheet: Identifiable, Hashable {
    case addCard            // SelectTemplateSheetController (添加项目)
    case addNote            // 添加笔记
    case addLabel           // AddLabelSheetController
    case editCardLabel(id: Int) // rename_label_title
    case selectColorCardLabel(id: Int) // SelectColorViewController for labels
    case addTemplate        // save_as_template (存为模板)
    case sorting            // SortingSheetController
    case generator          // PasswordOptionsSheetController
    case labels(cardId: Int) // SetLabelsSheetController
    case addField           // AddFieldSheetController
    case editField          // EditFieldSheetController
    case selectSymbol       // SelectSymbolViewController
    case selectColor        // SelectColorViewController (cards)
    case selectTexture      // SelectTextureSheetController
    case selectTemplate     // template picker inside edit-card
    case history            // HistorySheetController (recent)
    case passwordHistory    // password_history_command
    case exportAs           // ExportAsSheetController
    case importData         // ImportSheetController + ImportSourceViewController
    case databaseInfo       // DatabaseInfoSheetController
    case compromised        // CompromisedPasswordsSheetController
    case changePassword     // SetPasswordSheetController
    case configureCloud     // ConfigureCloudSheetController
    case eraseData          // 擦除数据 confirm
    case manageDatabases    // ManageDatabasesViewController
    case selectDatabase     // SelectDatabaseSheetController
    case preferences        // 设置 window
    case about              // AboutWindowController
    case whatsNew           // WhatsNewSheetController
    case premium            // PremiumSheetController
    case setupPlan          // SetupPlanViewController
    case enterPassword      // EnterPasswordSheetController (unlock)
    case expiredCards       // expiring_cards_warning prompt
    case restoreTemplates   // restore_templates_query

    var id: String {
        switch self {
        case .addCard: return "addCard"
        case .addNote: return "addNote"
        case .addLabel: return "addLabel"
        case .editCardLabel(let id): return "editLabel:\(id)"
        case .selectColorCardLabel(let id): return "selectColorLabel:\(id)"
        case .addTemplate: return "addTemplate"
        case .sorting: return "sorting"
        case .generator: return "generator"
        case .labels(let id): return "labels:\(id)"
        case .addField: return "addField"
        case .editField: return "editField"
        case .selectSymbol: return "selectSymbol"
        case .selectColor: return "selectColor"
        case .selectTexture: return "selectTexture"
        case .selectTemplate: return "selectTemplate"
        case .history: return "history"
        case .passwordHistory: return "passwordHistory"
        case .exportAs: return "exportAs"
        case .importData: return "importData"
        case .databaseInfo: return "databaseInfo"
        case .compromised: return "compromised"
        case .changePassword: return "changePassword"
        case .configureCloud: return "configureCloud"
        case .eraseData: return "eraseData"
        case .manageDatabases: return "manageDatabases"
        case .selectDatabase: return "selectDatabase"
        case .preferences: return "preferences"
        case .about: return "about"
        case .whatsNew: return "whatsNew"
        case .premium: return "premium"
        case .setupPlan: return "setupPlan"
        case .enterPassword: return "enterPassword"
        case .expiredCards: return "expiredCards"
        case .restoreTemplates: return "restoreTemplates"
        }
    }
}

extension AppContext {
    var selectedCard: Card? {
        selectedCardId.flatMap { database.card(id: $0) }
    }
}
