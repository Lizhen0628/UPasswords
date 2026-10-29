import CryptoKit
import Foundation
import Network

import UPasswordsCore
import UPasswordsPersistence

extension AppContext {
    /// Monitors policy changes; network recovery resumes transient failures only.
    func startAttachmentNetworkMonitor() {
        guard attachmentNetworkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAvailable = self.attachmentNetworkState.isAvailable
                let hadObservation = self.attachmentNetworkObserved
                self.attachmentNetworkObserved = true
                let kind: AttachmentNetworkKind
                if path.usesInterfaceType(.wifi) {
                    kind = .wifi
                } else if path.usesInterfaceType(.wiredEthernet) {
                    kind = .wired
                } else if path.usesInterfaceType(.cellular) {
                    kind = .cellular
                } else {
                    kind = .unknown
                }
                self.attachmentNetworkState = AttachmentNetworkState(
                    isAvailable: path.status == .satisfied, kind: kind, isConstrained: path.isConstrained)
                if hadObservation, !wasAvailable, path.status == .satisfied, self.isAttachmentSessionUnlocked {
                    do {
                        try self.updateAttachmentLedger { $0.restartTransientFailures() }
                    } catch {
                        self.reportAttachmentLedgerError(error)
                    }
                }
                self.requeueCurrentDownloadIfDisallowed()
                self.scheduleMissingAttachmentDownloads()
            }
        }
        // NWPathMonitor requires a dispatch queue; the callback is pinned to the main actor.
        monitor.start(queue: .main)
        attachmentNetworkMonitor = monitor
    }

    /// Reconstructs pending work from current references and durable version policy.
    func scheduleMissingAttachmentDownloads() {
        guard isAttachmentSessionUnlocked, !attachmentLedgerUnavailable else { return }
        do {
            let fingerprint = relay.token(database: databaseName).map { Data(SHA256.hash(data: Data($0.utf8))) }
            try updateAttachmentLedger {
                $0.reconcile(with: database)
                if let fingerprint { $0.resumeAfterAuthorization(fingerprint: fingerprint) }
            }
            for card in database.cards where hasMissingAttachmentContent(card) {
                enqueueAttachmentDownload(cardID: card.id, prioritized: false)
            }
            scheduleAttachmentRetry()
        } catch {
            reportAttachmentLedgerError(error)
        }
    }

    /// Opening a card resumes evicted caches; only an explicit retry resets failed attempts.
    func prioritizeAttachmentDownload(cardID: UUID, retryFailures: Bool = false) {
        guard isAttachmentSessionUnlocked else { return }
        do {
            let versions = AttachmentDownloadLedger.versions(in: database, cardID: cardID)
            try updateAttachmentLedger { ledger in
                for version in versions {
                    ledger.recordAccess(to: version)
                    ledger.request(version, resetFailures: retryFailures)
                }
            }
            enqueueAttachmentDownload(cardID: cardID, prioritized: true)
        } catch {
            reportAttachmentLedgerError(error)
        }
    }

    /// Whether a stable attachment is protected from automatic local cache eviction.
    func isAttachmentKeptOffline(cardID: UUID, attachmentID: UUID) -> Bool {
        attachmentDownloadLedger?.offlineAttachments.contains(
            .init(cardID: cardID, attachmentID: attachmentID)) == true
    }

    /// Persists the user's retention choice before scheduling any missing content.
    func setAttachmentKeptOffline(_ isKeptOffline: Bool, cardID: UUID, attachmentID: UUID) {
        guard isAttachmentSessionUnlocked else { return }
        let identity = AttachmentDownloadLedger.Identity(cardID: cardID, attachmentID: attachmentID)
        do {
            try updateAttachmentLedger { $0.setKeptOffline(isKeptOffline, for: identity) }
            Log.info("sync", "attachment offline retention cardId=\(cardID) attachmentId=\(attachmentID) enabled=\(isKeptOffline)")
            if isKeptOffline {
                prioritizeAttachmentDownload(cardID: cardID, retryFailures: true)
            }
        } catch {
            reportAttachmentLedgerError(error)
        }
    }

    /// Explains why missing content is queued, backing off, or paused.
    func attachmentDownloadStatusText(cardID: UUID) -> String? {
        guard let card = database.card(id: cardID), hasMissingAttachmentContent(card) else { return nil }
        if attachmentLedgerUnavailable { return L10n.t("attachment_download_state_error") }
        let versions = AttachmentDownloadLedger.versions(in: database, cardID: cardID, missingOnly: true)
        for version in versions {
            guard let record = attachmentDownloadLedger?.records[version] else { continue }
            if record.isEvicted { return L10n.t("attachment_cache_evicted") }
            switch record.failure {
            case .authorization: return L10n.t("attachment_download_authorization_required")
            case .integrity: return L10n.t("sync_attachment_integrity_failed")
            case .unavailable, .permanent: return L10n.t("attachment_download_unavailable")
            case .storage: return L10n.t("attachment_cache_space_limited")
            case .transient:
                return L10n.t(record.retryAt == nil ? "attachment_retry_limit" : "attachment_retry_scheduled")
            case nil: continue
            }
        }
        return L10n.t("attachment_content_unavailable")
    }

    func resumeAttachmentDownloads() {
        requeueCurrentDownloadIfDisallowed()
        guard attachmentDownloadTask == nil, nextAttachmentDownloadIsAllowed else { return }
        attachmentDownloadTask = Task { [weak self] in await self?.drainAttachmentDownloads() }
    }

    /// Cancels this session's work; durable retry limits and retention remain on disk.
    func cancelAttachmentDownloads() {
        attachmentDownloadQueue.cancelInFlight()
        attachmentDownloadTask?.cancel()
        attachmentRetryTask?.cancel()
        attachmentRetryTask = nil
        attachmentDownloadQueue.removeAll()
        attachmentDownloadLedger = nil
        attachmentLedgerUnavailable = false
        clearAttachmentDownloadStates()
    }

    private var isAttachmentSessionUnlocked: Bool { phase == .unlocked }

    private func updateAttachmentLedger(_ update: (inout AttachmentDownloadLedger) -> Void) throws {
        var ledger = try attachmentDownloadLedger ?? store.loadAttachmentDownloadLedger(for: databaseName)
        let previous = ledger
        update(&ledger)
        if ledger != previous {
            try store.saveAttachmentDownloadLedger(ledger, for: databaseName)
        }
        objectWillChange.send()
        attachmentDownloadLedger = ledger
    }

    private func reportAttachmentLedgerError(_ error: Error) {
        let shouldNotify = !attachmentLedgerUnavailable
        attachmentLedgerUnavailable = true
        attachmentRetryTask?.cancel()
        attachmentDownloadTask?.cancel()
        Log.error("sync", "attachment policy persistence failed; downloads paused: \(error)")
        if shouldNotify { AppToast.shared.show(L10n.t("attachment_download_state_error")) }
    }

    private func enqueueAttachmentDownload(cardID: UUID, prioritized: Bool) {
        guard isAttachmentSessionUnlocked, relayBound, !attachmentLedgerUnavailable,
              let card = database.card(id: cardID), hasMissingAttachmentContent(card),
              let ledger = attachmentDownloadLedger else { return }
        let ready = AttachmentDownloadLedger.versions(in: database, cardID: cardID, missingOnly: true)
            .contains { ledger.isReady($0) }
        guard ready else {
            setAttachmentDownloadState(.failed, cardID: cardID)
            return
        }
        attachmentDownloadQueue.enqueue(cardID: cardID, prioritized: prioritized)
        setAttachmentDownloadState(
            attachmentDownloadQueue.isActive(cardID: cardID) ? .downloading : .queued, cardID: cardID)
        resumeAttachmentDownloads()
    }

    private func drainAttachmentDownloads() async {
        defer {
            attachmentDownloadTask = nil
            // Other cards can outlast an earlier retry delay; rescan due versions before sleeping.
            if isAttachmentSessionUnlocked { scheduleMissingAttachmentDownloads() }
        }
        while !Task.isCancelled, nextAttachmentDownloadIsAllowed {
            guard let binding = relay.binding(database: databaseName),
                  let token = relay.token(database: databaseName), let snapshotKey = vaultKey,
                  let entry = attachmentDownloadQueue.takeNext() else { break }
            let cardID = entry.cardID
            let name = databaseName
            let sessionID = syncSessionID
            let key = RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) })
            var activeVersion: AttachmentDownloadLedger.Version?
            let startedAt = Date()
            do {
                while syncState == .syncing {
                    try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                    try await Task.sleep(for: .milliseconds(100))
                }
                let versions = AttachmentDownloadLedger.versions(in: database, cardID: cardID, missingOnly: true)
                guard let version = versions.first(where: { attachmentDownloadLedger?.isReady($0) == true }) else {
                    attachmentDownloadQueue.finish(cardID: cardID)
                    refreshAttachmentDownloadState(cardID: cardID)
                    continue
                }
                activeVersion = version
                setAttachmentDownloadState(.downloading, cardID: cardID)
                let protected = Set(AttachmentDownloadLedger.versions(in: database, cardID: cardID))
                // Reserve the actual size after verification; a worst-case reservation would
                // incorrectly pause small files that still fit within the remaining budget.
                try applyAttachmentCacheBudget(incomingBytes: 0,
                                               protecting: protected, key: key, vaultKey: snapshotKey)
                Log.info("sync", "attachment download started cardId=\(cardID) attachmentId=\(version.identity.attachmentID) priority=\(entry.isPrioritized)")
                let data = try await RowSync.downloadAttachment(
                    version: version, client: relayClient, token: token, vaultId: binding.vaultId, key: key)
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                guard relay.binding(database: name) == binding, relay.token(database: name) == token else {
                    throw CancellationError()
                }
                while syncState == .syncing {
                    try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                    try await Task.sleep(for: .milliseconds(100))
                }
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                guard relay.binding(database: name) == binding, relay.token(database: name) == token else {
                    throw CancellationError()
                }
                try applyAttachmentCacheBudget(incomingBytes: data.count, protecting: protected,
                                               key: key, vaultKey: snapshotKey)
                var current = database
                if RowSync.installDownloadedAttachmentContent(data, for: version, into: &current) {
                    try commitSyncSnapshot(current, name: name, vaultKey: snapshotKey, state: rowSync)
                    database = current
                    SafariSnapshotBridge.push(databaseName: databaseName, store: store)
                    try updateAttachmentLedger {
                        $0.recordSuccess(for: version)
                        $0.reconcile(with: current)
                    }
                }
                let priority = attachmentDownloadQueue.inFlightIsPrioritized
                attachmentDownloadQueue.finish(cardID: cardID)
                refreshAttachmentDownloadState(cardID: cardID)
                enqueueAttachmentDownload(cardID: cardID, prioritized: priority)
                Log.info("sync", "attachment download finished cardId=\(cardID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            } catch is CancellationError {
                attachmentDownloadQueue.finish(cardID: cardID)
                break
            } catch {
                let priority = attachmentDownloadQueue.inFlightIsPrioritized
                attachmentDownloadQueue.finish(cardID: cardID)
                guard !Task.isCancelled, isAttachmentSessionUnlocked, relayBound,
                      syncSessionID == sessionID, databaseName == name, vaultKey == snapshotKey,
                      relay.binding(database: name) == binding, relay.token(database: name) == token else { break }
                guard let activeVersion else {
                    reportAttachmentLedgerError(error)
                    break
                }
                let classification = AttachmentDownloadFailure.classify(error)
                do {
                    try updateAttachmentLedger {
                        $0.recordFailure(for: activeVersion, failure: classification.failure,
                                         minimumDelay: classification.minimumDelay)
                    }
                } catch {
                    reportAttachmentLedgerError(error)
                    break
                }
                refreshAttachmentDownloadState(cardID: cardID)
                enqueueAttachmentDownload(cardID: cardID, prioritized: priority)
                Log.error("sync", "attachment download failed cardId=\(cardID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)): \(error)")
            }
        }
    }

    private func refreshAttachmentDownloadState(cardID: UUID) {
        let isMissing = database.card(id: cardID).map(hasMissingAttachmentContent) ?? false
        setAttachmentDownloadState(isMissing ? .failed : nil, cardID: cardID)
    }

    private func applyAttachmentCacheBudget(
        incomingBytes: Int, protecting: Set<AttachmentDownloadLedger.Version>,
        key: RowSyncKey, vaultKey: SymmetricKey
    ) throws {
        guard let ledger = attachmentDownloadLedger else { throw RowSyncSafetyError.invalidResponse }
        let plan = try AttachmentCachePolicy.makePlan(
            database: database, state: rowSync, key: key, ledger: ledger,
            incomingBytes: incomingBytes, protectedVersions: protecting)
        guard plan.hasCapacity else { throw CocoaError(.fileWriteOutOfSpace) }
        let available = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity
        // Encrypted XML and atomic staging need headroom beyond the raw incoming bytes.
        let requiredBytes = max(64 * 1024 * 1024, incomingBytes * 4)
        if let available, available < requiredBytes { throw CocoaError(.fileWriteOutOfSpace) }
        guard !plan.evictedVersions.isEmpty else { return }
        try store.saveAttachmentDownloadLedger(plan.ledger, for: databaseName)
        attachmentDownloadLedger = plan.ledger
        try commitSyncSnapshot(plan.database, name: databaseName, vaultKey: vaultKey, state: rowSync)
        for version in plan.evictedVersions {
            try nativeStore?.evictAttachmentContent(
                vaultName: databaseName,
                attachmentID: version.identity.attachmentID,
                contentVersion: version.contentVersion
            )
        }
        database = plan.database
        SafariSnapshotBridge.push(databaseName: databaseName, store: store)
        Log.info("sync", "attachment cache evicted versions=\(plan.evictedVersions.count) cachedBytes=\(plan.cachedBytes)")
    }

    private func scheduleAttachmentRetry() {
        attachmentRetryTask?.cancel()
        attachmentRetryTask = nil
        guard isAttachmentSessionUnlocked, relayBound, !attachmentLedgerUnavailable,
              let retryAt = attachmentDownloadLedger?.nextRetry(in: database) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let delay = max(0, retryAt.timeIntervalSinceNow)
        attachmentRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard let self, self.isAttachmentSessionUnlocked,
                  self.databaseName == name, self.syncSessionID == sessionID else { return }
            self.attachmentRetryTask = nil
            self.scheduleMissingAttachmentDownloads()
        }
    }

    private var nextAttachmentDownloadIsAllowed: Bool {
        guard isAttachmentSessionUnlocked, relayBound, !attachmentLedgerUnavailable,
              relay.token(database: databaseName) != nil, vaultKey != nil,
              let next = attachmentDownloadQueue.firstCardID else { return false }
        return isAttachmentNetworkAllowed(prioritized: attachmentDownloadQueue.isPrioritized(next))
    }

    private func isAttachmentNetworkAllowed(prioritized: Bool) -> Bool {
        if prioritized { return AttachmentDownloadPolicy.allowsPrioritized(attachmentNetworkState) }
        return AttachmentDownloadPolicy.allowsBackground(
            on: attachmentNetworkState, allowsCellular: settings.downloadAttachmentsOnCellular, allowsUnknown: settings.downloadAttachmentsOnUnknownNetwork)
    }

    private func requeueCurrentDownloadIfDisallowed() {
        guard let cardID = attachmentDownloadQueue.inFlightCardID,
              !isAttachmentNetworkAllowed(prioritized: attachmentDownloadQueue.inFlightIsPrioritized) else { return }
        attachmentDownloadQueue.requeueInFlight()
        setAttachmentDownloadState(.queued, cardID: cardID)
        attachmentDownloadTask?.cancel()
    }

    private func hasMissingAttachmentContent(_ card: Card) -> Bool {
        (card.images + card.files).contains { !$0.hasContent }
    }
}
