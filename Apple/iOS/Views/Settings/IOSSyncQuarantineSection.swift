import SwiftUI
import UPasswordsCore
import UPasswordsPersistence

/// Shows retained remote sync records without exposing their encrypted payloads.
struct IOSSyncQuarantineSection: View {
    @EnvironmentObject private var vault: Vault

    private var items: [RowSyncQuarantinedItem] {
        vault.rowSync.quarantinedItems.values.sorted {
            ($0.sequence ?? Int.max, $0.uuid.uuidString) < ($1.sequence ?? Int.max, $1.uuid.uuidString)
        }
    }

    private var candidates: [RowSyncQuarantinedCandidate] {
        vault.rowSync.quarantinedCandidates.values.sorted {
            ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id)
        }
    }

    var body: some View {
        if !items.isEmpty || !candidates.isEmpty {
            Section(L10n.t("sync_quarantine_title")) {
                Text(String(format: L10n.t("sync_quarantine_summary_fmt"), items.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !candidates.isEmpty {
                    Text(String(format: L10n.t("sync_candidate_quarantine_summary_fmt"), candidates.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(itemLabel(item))
                        Text(reasonLabel(item.reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(candidates) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidateLabel(item))
                        Text(reasonLabel(item.reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task {
                        await vault.retryQuarantinedSyncItems()
                        await vault.retryQuarantinedSyncConflictCandidates()
                    }
                } label: {
                    Label(L10n.t("sync_quarantine_retry"), systemImage: "arrow.clockwise")
                }
                .disabled(vault.locked || !vault.relayBound || vault.syncState == .syncing)
            }
        }
    }

    private func reasonLabel(_ reason: RowSyncQuarantinedCandidate.Reason) -> String {
        switch reason {
        case .authenticationFailed: return L10n.t("sync_quarantine_authentication_failed")
        case .unsupportedFormat: return L10n.t("sync_quarantine_unsupported_format")
        }
    }

    private func candidateLabel(_ item: RowSyncQuarantinedCandidate) -> String {
        String(format: L10n.t("sync_candidate_quarantine_fmt"),
                String(item.itemUUID.uuidString.prefix(8)),
                String(item.candidateID.prefix(8)))
    }

    private func itemLabel(_ item: RowSyncQuarantinedItem) -> String {
        let identifier = String(item.uuid.uuidString.prefix(8))
        if let sequence = item.sequence {
            return String(format: L10n.t("sync_quarantine_change_fmt"), sequence, identifier)
        }
        return String(format: L10n.t("sync_quarantine_snapshot_fmt"), identifier)
    }

    private func reasonLabel(_ reason: RowSyncQuarantinedItem.Reason) -> String {
        switch reason {
        case .authenticationFailed: return L10n.t("sync_quarantine_authentication_failed")
        case .unsupportedFormat: return L10n.t("sync_quarantine_unsupported_format")
        }
    }
}
