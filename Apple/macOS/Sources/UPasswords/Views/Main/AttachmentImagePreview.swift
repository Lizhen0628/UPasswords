import SwiftUI
import UPasswordsCore

struct AttachmentImagePreview: View {
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
        VStack(spacing: 0) {
            toolbar
            Divider()
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
                            ContentUnavailableView(
                                L10n.t("attachment_content_unavailable"), systemImage: "icloud.slash")
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        } else if hasDecodeFailed {
                            ContentUnavailableView(
                                L10n.t("attachment_preview_failed"), systemImage: "exclamationmark.triangle")
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
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 420)
        .accessibilityAction(.escape) { dismiss() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(attachment.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button(action: zoomOut) {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoomScale <= minimumZoom)
            .accessibilityLabel(L10n.t("attachment_zoom_out"))
            .help(L10n.t("attachment_zoom_out"))

            Button(action: resetZoom) {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel(L10n.t("attachment_zoom_reset"))
            .help(L10n.t("attachment_zoom_reset"))

            Button(action: zoomIn) {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoomScale >= maximumZoom)
            .accessibilityLabel(L10n.t("attachment_zoom_in"))
            .help(L10n.t("attachment_zoom_in"))

            Button(L10n.t("save_button"), systemImage: "square.and.arrow.down", action: onExport)
                .help(L10n.t("save_button"))

            Button(L10n.t("close_button")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(12)
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
