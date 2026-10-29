import Foundation

import UPasswordsCore
import UPasswordsPersistence

extension Vault {
    /// Imports selected cards as new destination rows after revalidating the source snapshot.
    /// - Parameters:
    ///   - sourceName: Local database containing the reviewed cards.
    ///   - sourcePassword: Master password for the source database.
    ///   - sourceFingerprint: Encrypted source body fingerprint displayed during review.
    ///   - destinationName: Destination database shown in the review.
    ///   - selectedCardIDs: Source card IDs selected by the user.
    /// - Returns: Import summary and the committed destination snapshot.
    /// - Throws: Source validation, destination state, selection, or atomic commit errors.
    func importCards(
        from sourceName: String,
        sourcePassword: String,
        sourceFingerprint: Data,
        into destinationName: String,
        selecting selectedCardIDs: Set<UUID>
    ) throws -> CrossDatabaseCardImporter.Plan {
        guard destinationName == databaseName else {
            throw CrossDatabaseCardImporter.ImportError.destinationChanged
        }
        guard sourceName != databaseName else {
            throw CrossDatabaseCardImporter.ImportError.sameDatabase
        }
        guard !locked, let vaultKey else {
            throw CrossDatabaseCardImporter.ImportError.destinationUnavailable
        }
        guard syncState != .syncing else {
            throw CrossDatabaseCardImporter.ImportError.destinationSyncing
        }

        let startedAt = Date()
        Log.info("db", "card import started source=\"\(sourceName)\" destination=\"\(databaseName)\" selected=\(selectedCardIDs.count)")
        let source = try store.loadCardImportSource(
            name: sourceName, password: sourcePassword, matching: sourceFingerprint)
        let plan = try CrossDatabaseCardImporter.makePlan(
            from: source,
            into: database,
            syncState: rowSync,
            selecting: selectedCardIDs)
        guard !plan.importedCardIDs.isEmpty else { return plan }

        try commitSyncSnapshot(plan.database, name: databaseName, vaultKey: vaultKey, state: plan.syncState)
        database = plan.database
        rowSync = plan.syncState
        Log.info(
            "app",
            "ios imported cards from \"\(sourceName)\" into \"\(databaseName)\" count=\(plan.importedCardIDs.count) labels=\(plan.createdLabelCount) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")

        if relay.binding(database: databaseName) != nil {
            Task { [weak self] in await self?.sync(auto: true) }
        }
        return plan
    }
}
