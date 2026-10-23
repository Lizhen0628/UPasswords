import SwiftUI
import UPasswordsCore

struct PersonalInfoSheet: View {
    @EnvironmentObject private var ctx: AppContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PersonalInfoDraft()

    var body: some View {
        VStack {
            PersonalInfoStepView(
                draft: $draft,
                onContinue: {
                    ctx.savePersonalInfo(draft)
                    dismiss()
                },
                onSkip: {
                    Log.info("ui", "personal information editor cancelled")
                    dismiss()
                }
            )
            Button(L10n.t("delete_button"), role: .destructive) {
                ctx.savePersonalInfo(PersonalInfoDraft())
                dismiss()
            }
            .padding(.bottom)
        }
        .frame(width: 620, height: 580)
        .onAppear { draft = PersonalInfoDraft(profile: ctx.database.userProfiles.first) }
    }
}
