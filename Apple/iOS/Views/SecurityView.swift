import SwiftUI

import UPasswordsCore

// MARK: - 安全检查 Tab

struct SecurityView: View {
    @EnvironmentObject var vault: Vault

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summaryGrid
                breachSection
                issueLists
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Brand.bg)
        .navigationTitle(L10n.t("ios_tab_security"))
        .navigationDestination(for: Card.self) { card in
            CardDetailView(cardID: card.id)
        }
    }

    // MARK: 总览

    private var summaryGrid: some View {
        let stats: [(title: String, count: Int, tint: Color, icon: String)] = [
            (L10n.t("ios_sec_weak"), vault.weakCards.count, Brand.yellow, "exclamationmark.triangle.fill"),
            (L10n.t("ios_sec_reused"), vault.reusedGroups.count, Brand.yellow, "repeat"),
            (L10n.t("ios_sec_compromised"), vault.compromisedCards.count, Brand.red, "exclamationmark.shield.fill"),
            (L10n.t("ios_cat_expiring"), vault.expiringCards.count, Brand.accent, "hourglass"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(0..<stats.count, id: \.self) { i in
                let s = stats[i]
                HStack(spacing: 12) {
                    Image(systemName: s.icon)
                        .font(.title3)
                        .foregroundStyle(s.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.count)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(Brand.fg)
                        Text(s.title)
                            .font(.footnote)
                            .foregroundStyle(Brand.muted)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: 泄露检查(k-匿名)

    private var breachSection: some View {
        BrandSection(title: L10n.t("ios_sec_breach_section")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Brand.accent)
                    Text(L10n.t("ios_sec_kanonimity_text"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let last = vault.lastBreachCheck {
                    Text(vault.breachResultOffline
                         ? String(format: L10n.t("ios_sec_last_check_offline_fmt"), last.formatted(date: .abbreviated, time: .shortened))
                         : String(format: L10n.t("ios_sec_last_check_fmt"), last.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(Brand.fg.opacity(0.4))
                }
                Button {
                    Task { await vault.runBreachCheck() }
                } label: {
                    HStack(spacing: 8) {
                        if vault.breachChecking {
                            ProgressView().tint(Brand.onAccent)
                        }
                        Text(vault.breachChecking ? L10n.t("ios_sec_checking_text") : L10n.t("ios_sec_check_now_button"))
                    }
                    .primaryButtonStyle()
                }
                .disabled(vault.breachChecking)
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    // MARK: 问题清单

    @ViewBuilder
    private var issueLists: some View {
        issueSection(title: L10n.t("ios_sec_compromised"), tint: Brand.red, cards: vault.compromisedCards,
                     emptyOK: vault.lastBreachCheck != nil)
        issueSection(title: L10n.t("ios_sec_weak"), tint: Brand.yellow, cards: vault.weakCards, emptyOK: false)
        reusedSection
        issueSection(title: L10n.t("ios_sec_expiring_section"), tint: Brand.accent, cards: vault.expiringCards, emptyOK: false)
    }

    @ViewBuilder
    private func issueSection(title: String, tint: Color, cards: [Card], emptyOK: Bool) -> some View {
        if !cards.isEmpty || emptyOK {
            BrandSection(title: String(format: L10n.t("ios_section_count_fmt"), title, cards.count)) {
                if cards.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                        Text(L10n.t("ios_sec_no_issues_text")).foregroundStyle(Brand.muted)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                } else {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                        NavigationLink(value: card) { CardRowView(card: card) }
                            .buttonStyle(.plain)
                        if i < cards.count - 1 { InsetDivider(leading: 68) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reusedSection: some View {
        let groups = vault.reusedGroups
        if !groups.isEmpty {
            BrandSection(title: String(format: L10n.t("ios_sec_reused_groups_fmt"), groups.count)) {
                ForEach(Array(groups.keys.enumerated()), id: \.offset) { gi, pw in
                    let ids = groups[pw] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ids, id: \.self) { id in
                            if let card = vault.cards.first(where: { $0.id == id }) {
                                NavigationLink(value: card) { CardRowView(card: card) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if gi < groups.count - 1 { InsetDivider() }
                }
            }
        }
    }
}
