import SwiftUI
import UPasswordsCore

struct AttachmentPreviewSheet: View {
    let attachment: Attachment
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @GestureState private var pinchScale: CGFloat = 1
    @State private var image: CGImage?
    @State private var hasDecodeFailed = false
    @State private var zoomScale: CGFloat = 1

    private let minimumZoom: CGFloat = 1
    private let maximumZoom: CGFloat = 4

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let targetPixelSize = maxPixelSize(for: geometry.size)
                let zoom = clampedZoom(zoomScale * pinchScale)
                let canvasSize = CGSize(
                    width: max(geometry.size.width, geometry.size.width * zoom),
                    height: max(geometry.size.height, geometry.size.height * zoom))

                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if let image {
                            Image(decorative: image, scale: displayScale)
                                .resizable()
                                .scaledToFit()
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        } else if attachment.data == nil {
                            EmptyStateView(
                                icon: "icloud.slash",
                                title: L10n.t("attachment_content_unavailable"))
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        } else if hasDecodeFailed {
                            EmptyStateView(
                                icon: "exclamationmark.triangle",
                                title: L10n.t("attachment_preview_failed"))
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        } else {
                            ProgressView()
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .task(id: taskID(targetPixelSize)) {
                        await loadImage(maxPixelSize: targetPixelSize)
                    }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinchScale) { value, state, _ in
                            state = value.magnification
                        }
                        .onEnded { value in
                            zoomScale = clampedZoom(zoomScale * value.magnification)
                        })
                .background(Brand.bg)
            }
            .safeAreaInset(edge: .bottom) {
                zoomControls
            }
            .background(Brand.bg)
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close_button")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(L10n.t("save_button"))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityAction(.escape) { dismiss() }
    }

    private var zoomControls: some View {
        HStack(spacing: 20) {
            zoomButton("minus.magnifyingglass", label: L10n.t("attachment_zoom_out"),
                       disabled: zoomScale <= minimumZoom, action: zoomOut)
            zoomButton("arrow.counterclockwise", label: L10n.t("attachment_zoom_reset"),
                       disabled: false, action: resetZoom)
            zoomButton("plus.magnifyingglass", label: L10n.t("attachment_zoom_in"),
                       disabled: zoomScale >= maximumZoom, action: zoomIn)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func zoomButton(
        _ symbol: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func maxPixelSize(for size: CGSize) -> Int {
        let requested = max(size.width, size.height) * displayScale * maximumZoom
        return max(512, min(4096, Int(requested.rounded(.up))))
    }

    private func taskID(_ pixelSize: Int) -> String {
        "\(attachment.id.uuidString):\(attachment.contentVersion.uuidString):\(pixelSize)"
    }

    private func loadImage(maxPixelSize: Int) async {
        guard let data = attachment.data else {
            image = nil
            hasDecodeFailed = false
            return
        }
        image = nil
        hasDecodeFailed = false
        let decodedImage = await Task.detached(priority: .userInitiated) {
            AttachmentImageDecoder.thumbnail(data: data, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        image = decodedImage
        hasDecodeFailed = decodedImage == nil
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoom), maximumZoom)
    }

    private func zoomIn() {
        zoomScale = clampedZoom(zoomScale + 0.5)
    }

    private func zoomOut() {
        zoomScale = clampedZoom(zoomScale - 0.5)
    }

    private func resetZoom() {
        zoomScale = minimumZoom
    }
}
