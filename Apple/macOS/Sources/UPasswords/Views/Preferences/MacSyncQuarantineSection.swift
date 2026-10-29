import SwiftUI
import UPasswordsCore
import UPasswordsPersistence

/// Shows retained remote sync records without exposing their encrypted payloads.
struct MacSyncQuarantineSection: View {
    @EnvironmentObject private var ctx: AppContext

    private var items: [RowSyncQuarantinedItem] {
        ctx.rowSync.quarantinedItems.values.sorted {
            ($0.sequence ?? Int.max, $0.uuid.uuidString) < ($1.sequence ?? Int.max, $1.uuid.uuidString)
        }
    }

    private var candidates: [RowSyncQuarantinedCandidate] {
        ctx.rowSync.quarantinedCandidates.values.sorted {
            ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id)
        }
    }

    var body: some View {
        if !items.isEmpty || !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("sync_quarantine_title"))
                    .font(.headline)
                Text(String(format: L10n.t("sync_quarantine_summary_fmt"), items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !candidates.isEmpty {
                    Text(String(format: L10n.t("sync_candidate_quarantine_summary_fmt"), candidates.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(itemLabel(item))
                            Text(reasonLabel(item.reason))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(candidates) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidateLabel(item))
                            Text(reasonLabel(item.reason))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(L10n.t("sync_quarantine_retry")) {
                    Task {
                        await ctx.retryQuarantinedSyncItems()
                        await ctx.retryQuarantinedSyncConflictCandidates()
                    }
                }
                .disabled(ctx.phase != .unlocked || !ctx.relayBound || ctx.syncState == .syncing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    private func itemLabel(_ item: RowSyncQuarantinedItem) -> String {
        let identifier = String(item.uuid.uuidString.prefix(8))
        if let sequence = item.sequence {
            return String(format: L10n.t("sync_quarantine_change_fmt"), sequence, identifier)
        }
        return String(format: L10n.t("sync_quarantine_snapshot_fmt"), identifier)
    }

    private func candidateLabel(_ item: RowSyncQuarantinedCandidate) -> String {
        String(format: L10n.t("sync_candidate_quarantine_fmt"),
                String(item.itemUUID.uuidString.prefix(8)),
                String(item.candidateID.prefix(8)))
    }

    private func reasonLabel(_ reason: RowSyncQuarantinedItem.Reason) -> String {
        switch reason {
        case .authenticationFailed: return L10n.t("sync_quarantine_authentication_failed")
        case .unsupportedFormat: return L10n.t("sync_quarantine_unsupported_format")
        }
    }

    private func reasonLabel(_ reason: RowSyncQuarantinedCandidate.Reason) -> String {
        switch reason {
        case .authenticationFailed: return L10n.t("sync_quarantine_authentication_failed")
        case .unsupportedFormat: return L10n.t("sync_quarantine_unsupported_format")
        }
    }
}
