import SwiftUI

// MARK: - Select texture (SelectTextureSheetController + TextureCell)

struct SelectTextureSheet: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("select_texture_title"),
            minWidth: 520,
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(L10n.t("lock_screen_background_prompt")) \(L10n.t("lock_screen_preview_prompt"))")
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                            ForEach(0..<LockTextures.count, id: \.self) { i in
                                Button {
                                    settings.lockTexture = i
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        LockTextures.gradient(for: i)
                                            .frame(width: 100, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        if settings.lockTexture == i {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white)
                                                .padding(4)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Picker(L10n.t("lock_screen_text_prompt"), selection: $settings.lockWhiteText) {
                        Text(L10n.t("white_text_text")).tag(true)
                        Text(L10n.t("black_text_text")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        )
    }
}

