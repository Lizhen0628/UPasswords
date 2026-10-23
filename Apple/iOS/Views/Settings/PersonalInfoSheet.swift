import SwiftUI
import UPasswordsCore

struct PersonalInfoSheet: View {
    @EnvironmentObject private var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PersonalInfoDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("personal_info_given_name"), text: $draft.givenName)
                    TextField(L10n.t("personal_info_family_name"), text: $draft.familyName)
                    TextField(L10n.t("personal_info_email"), text: $draft.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.t("personal_info_phone"), text: $draft.phone)
                        .keyboardType(.phonePad)
                    TextField(L10n.t("personal_info_address_line_1"), text: $draft.addressLine1)
                    TextField(L10n.t("personal_info_address_line_2"), text: $draft.addressLine2)
                    TextField(L10n.t("personal_info_city"), text: $draft.city)
                    TextField(L10n.t("personal_info_region"), text: $draft.region)
                    TextField(L10n.t("personal_info_postal_code"), text: $draft.postalCode)
                    TextField(L10n.t("personal_info_country"), text: $draft.country)
                } footer: {
                    Text(L10n.t("personal_info_hint"))
                }
                Section {
                    Button(L10n.t("delete_button"), role: .destructive) {
                        vault.savePersonalInfo(PersonalInfoDraft())
                        dismiss()
                    }
                }
            }
            .navigationTitle(L10n.t("personal_info_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) {
                        Log.info("ui", "ios personal information editor cancelled")
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("save_button")) {
                        vault.savePersonalInfo(draft)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { draft = PersonalInfoDraft(profile: vault.database.userProfiles.first) }
    }
}
