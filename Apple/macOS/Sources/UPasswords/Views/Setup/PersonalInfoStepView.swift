import SwiftUI
import UPasswordsCore

/// 建库引导中的个人资料草稿表单；库可用后由会话层统一保存。
struct PersonalInfoStepView: View {
    @Binding var draft: PersonalInfoDraft
    var onContinue: () -> Void
    var onSkip: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(L10n.t("personal_info_title"))
                    .font(.title2.bold())
                Text(L10n.t("personal_info_hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledRow(label: L10n.t("personal_info_given_name")) {
                            TextField("", text: $draft.givenName).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_family_name")) {
                            TextField("", text: $draft.familyName).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_email")) {
                            TextField("", text: $draft.email).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_phone")) {
                            TextField("", text: $draft.phone).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_address_line_1")) {
                            TextField("", text: $draft.addressLine1).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_address_line_2")) {
                            TextField("", text: $draft.addressLine2).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_city")) {
                            TextField("", text: $draft.city).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_region")) {
                            TextField("", text: $draft.region).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_postal_code")) {
                            TextField("", text: $draft.postalCode).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("personal_info_country")) {
                            TextField("", text: $draft.country).textFieldStyle(.roundedBorder)
                        }
                    }
                    .frame(maxWidth: 440)
                }
                Button(L10n.t("continue_button"), action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(L10n.t("skip_button"), action: onSkip)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }
}
