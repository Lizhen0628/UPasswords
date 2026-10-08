import SwiftUI
import AVFoundation

import UPasswordsCore

// MARK: - 二维码展示（OTP 搬运到其他验证器/设备）

struct QRCodeSheet: View {
    let title: String
    let payload: String
    @Environment(\.dismiss) private var dismiss

    private var image: UIImage? {
        try? QRCodeService.generate(payload)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let image {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Text(L10n.t("qr_generate_failed", fallback: "二维码生成失败。"))
                            .font(.subheadline)
                            .foregroundStyle(Brand.red)
                            .padding(.vertical, 60)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                    Text(L10n.t("ios_qr_hint"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            .background(Brand.bg)
            .navigationTitle(L10n.t("ios_qr_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("ios_done_button")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - 相机扫码（AVFoundation 元数据输出,识别首个可用负载即回调）

struct QRScannerView: UIViewControllerRepresentable {
    /// 命中可用负载时回调一次（会话随即停止）。
    let onScan: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onUnavailable: () -> Void
        /// 防抖:连续帧会重复输出,只取第一个可解析负载。
        private var delivered = false

        init(onScan: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onScan = onScan
            self.onUnavailable = onUnavailable
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered else { return }
            let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            guard let payload = try? QRCodeService.firstOTP(from: payloads) else { return }
            delivered = true
            DispatchQueue.main.async { [onScan] in
                onScan(payload)
            }
        }

        func sessionWasInterrupted(_ session: AVCaptureSession) {}

        func sessionDidStopRunning(_ session: AVCaptureSession) {}
    }
}

final class ScannerViewController: UIViewController {
    weak var coordinator: QRScannerView.Coordinator?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "upasswords.qrscanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [session] in
            guard session.inputs.isEmpty else { return }
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [self] in setupCapturePipeline() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                if granted {
                    self.sessionQueue.async { self.setupCapturePipeline() }
                } else {
                    DispatchQueue.main.async { [self] in notifyUnavailable() }
                }
            }
        default:
            DispatchQueue.main.async { [self] in notifyUnavailable() }
        }
    }

    private func setupCapturePipeline() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { [self] in notifyUnavailable() }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [self] in notifyUnavailable() }
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [self] in notifyUnavailable() }
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        session.startRunning()
    }

    private func notifyUnavailable() {
        coordinator?.onUnavailable()
    }
}

/// 扫码全屏页:相机预览 + 提示浮层 + 权限失败态。
struct QRScannerSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if unavailable {
                VStack(spacing: 14) {
                    Image(systemName: "camera.badge.ellipsis")
                        .font(.system(size: 40))
                        .foregroundStyle(Brand.muted)
                    Text(L10n.t("ios_camera_permission_error"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.fg)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(L10n.t("ios_open_settings_button"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.accent)
                    }
                }
            } else {
                QRScannerView(
                    onScan: { payload in
                        onScan(payload)
                        dismiss()
                    },
                    onUnavailable: { unavailable = true }
                )
                .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text(L10n.t("ios_scan_hint"))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 48)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}
