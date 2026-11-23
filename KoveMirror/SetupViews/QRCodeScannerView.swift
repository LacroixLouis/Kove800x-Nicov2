import SwiftUI
import AVFoundation
import AudioToolbox

struct QRCodeScannerView: UIViewControllerRepresentable {
    /// True when the scanned code was accepted and the sheet can close.
    var onScan: (String) -> Bool
    var onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ viewController: ScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        context.coordinator.onFailure = onFailure
    }
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onFailure: onFailure) }

    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        var onScan: (String) -> Bool
        var onFailure: (String) -> Void
        init(onScan: @escaping (String) -> Bool, onFailure: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onFailure = onFailure
        }
        func scannerDidScan(code: String) -> Bool { onScan(code) }
        func scannerDidFail(error: String) { onFailure(error) }
    }
}

protocol ScannerViewControllerDelegate: AnyObject {
    func scannerDidScan(code: String) -> Bool
    func scannerDidFail(error: String)
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?
    private let cameraQueue = DispatchQueue(label: "DoubleInterface.camera.session")
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var accepted = false
    private var previousCode: String?
    private var previousAttempt = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureCamera() }
                    else { self.delegate?.scannerDidFail(error: "Autorise la caméra dans Réglages → Double Interface → Caméra.") }
                }
            }
        default:
            delegate?.scannerDidFail(error: "Autorise la caméra dans Réglages → Double Interface → Caméra.")
        }
    }

    private func configureCamera() {
        guard captureSession == nil, !accepted else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            delegate?.scannerDidFail(error: "Aucune caméra disponible sur cet iPhone.")
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.configuration }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { throw CameraError.configuration }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            captureSession = session
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            previewLayer = preview
            cameraQueue.async { if !session.isRunning { session.startRunning() } }
        } catch {
            session.commitConfiguration()
            delegate?.scannerDidFail(error: "Impossible de démarrer le scanner : \(error.localizedDescription)")
        }
    }
    private enum CameraError: LocalizedError {
        case configuration
        var errorDescription: String? { "Impossible d’accéder au flux de la caméra." }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let session = captureSession, !accepted else { return }
        cameraQueue.async { if !session.isRunning { session.startRunning() } }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let session = captureSession else { return }
        cameraQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !accepted,
              let item = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = item.stringValue else { return }
        let now = Date()
        // Rejecting a download QR must not permanently stop the camera.
        // Throttle the same bad QR so error text does not flicker each frame.
        guard previousCode != value || now.timeIntervalSince(previousAttempt) > 1.5 else { return }
        previousCode = value
        previousAttempt = now
        if delegate?.scannerDidScan(code: value) == true {
            accepted = true
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            if let session = captureSession {
                cameraQueue.async { if session.isRunning { session.stopRunning() } }
            }
        }
    }
}
