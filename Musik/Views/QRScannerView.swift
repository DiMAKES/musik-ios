import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera that reads the "add this server" QR from the web UI.
struct QRScannerSheet: View {
    var onLink: (ConnectLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch access {
                case .authorized:
                    CameraScanner(onCode: handle)
                        .ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 3)
                        .frame(width: 250, height: 250)
                case .notDetermined:
                    ProgressView().tint(.white)
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            access = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                default:
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill").font(.system(size: 40))
                        Text("Нет доступа к камере").font(.headline)
                        Text("Разреши его в настройках или введи адрес и токен вручную.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.muted)
                        Button("Открыть настройки") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(32)
                    .foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(hint ?? "Наведи камеру на QR-код: веб-интерфейс musik → Профиль → Настройки → «Показать QR»")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(hint == nil ? Color.white.opacity(0.85) : Color.red)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.6))
            }
            .navigationTitle("Сканировать QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private func handle(_ code: String) {
        guard let link = ConnectLink(code) else {
            hint = "Это не QR-код musik"
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onLink(link)
        dismiss()
    }
}

/// AVFoundation preview + QR metadata output (works on every device iOS 16 runs on).
private struct CameraScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
    }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = self.session
        // startRunning blocks; Apple asks to call it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    // Delivered on the main queue (see setMetadataObjectsDelegate above).
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, code != self.lastCode else { return }
            self.lastCode = code
            self.onCode?(code)
        }
    }
}
