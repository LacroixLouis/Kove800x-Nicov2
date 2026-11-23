import ReplayKit
import VideoToolbox
import Network
import CoreImage
import CoreVideo
import ImageIO

class SampleHandler: RPBroadcastSampleHandler, H264EncoderDelegate {
    // Network configuration and encoder access share one queue. ReplayKit's
    // borrowed sample buffer is consumed before its callback returns.
    private let worker = DispatchQueue(label: "com.nicolasrivet.broadcast-render", qos: .userInitiated)
    private let workerKey = DispatchSpecificKey<UInt8>()
    private var localConnection: NWConnection?
    private let encoder = H264Encoder()
    private let letterboxer = FrameLetterboxer()
    private var configPackets = NewlinePacketBuffer()
    private var active = false
    private var paused = false
    private var encoderReady = false
    private var targetWidth = 600
    private var targetHeight = 1024
    private var topPadding = 0
    private var bottomPadding = 0
    private var keepAspectRatio = false
    private var framing: BroadcastFraming = .fullScreen

    override init() {
        super.init()
        worker.setSpecific(key: workerKey, value: 1)
    }

    private func onWorker(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: workerKey) != nil { action() }
        else { worker.sync(execute: action) }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        onWorker {
            tearDown()
            active = true
            paused = false
            configPackets = NewlinePacketBuffer()
            encoder.delegate = self
            encoder.onError = { [weak self] status in
                guard let self else { return }
                self.worker.async {
                    guard self.active else { return }
                    self.fail("L’encodage vidéo a échoué (code \(status)). Relance la diffusion.")
                }
            }
            let preset = KoveScreenPreset.current
            targetWidth = preset.width
            targetHeight = preset.height
            topPadding = KoveScreenPreset.topPadding
            bottomPadding = KoveScreenPreset.bottomPadding
            keepAspectRatio = KoveScreenPreset.keepAspectRatio
            framing = KoveScreenPreset.broadcastFraming

            let connection = NWConnection(host: "127.0.0.1", port: 15455, using: .tcp)
            localConnection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.active, self.localConnection === connection else { return }
                switch state {
                case .ready:
                    self.startEncoder()
                    if self.active { self.receiveConfigUpdates(connection) }
                case .failed:
                    self.fail("La liaison de diffusion avec Double Interface a été interrompue.")
                default: break
                }
            }
            connection.start(queue: worker)
        }
    }

    private func startEncoder() {
        encoderReady = encoder.start(width: Int32(targetWidth), height: Int32(targetHeight), fps: 30)
        if !encoderReady { fail("Impossible de démarrer l’encodeur vidéo. Relance la diffusion.") }
    }

    private func receiveConfigUpdates(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.active, self.localConnection === connection else { return }
            if let data, !data.isEmpty { self.parseConfigData(data) }
            guard self.active else { return }
            if complete || error != nil {
                self.fail("La diffusion a perdu sa liaison avec Double Interface.")
            } else { self.receiveConfigUpdates(connection) }
        }
    }

    private func parseConfigData(_ data: Data) {
        let packets: [Data]
        do { packets = try configPackets.append(data) }
        catch { fail("La configuration vidéo reçue est invalide."); return }
        for packet in packets {
            guard let json = try? JSONSerialization.jsonObject(with: packet) as? [String: Any],
                  json["type"] as? String == "config" else { continue }
            if let top = json["top"] as? Int { topPadding = max(0, min(top, 300)) }
            if let bottom = json["bottom"] as? Int { bottomPadding = max(0, min(bottom, 300)) }
            if let aspect = json["keepAspect"] as? Bool { keepAspectRatio = aspect }
            // Older senders omit this key; preserve the selected crop.
            if let raw = json["framing"] as? String { framing = BroadcastFraming.load(raw) }
            if let w = json["width"] as? Int, let h = json["height"] as? Int,
               w != targetWidth || h != targetHeight {
                fail("Le format du compteur a changé. Reconnecte la vidéo puis relance la diffusion.")
                return
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        onWorker {
            guard active, !paused, encoderReady,
                  let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            autoreleasepool {
                let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber
                let orientation = raw.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
                guard let output = letterboxer.letterbox(pixelBuffer: buffer,
                    targetWidth: targetWidth, targetHeight: targetHeight,
                    topPadding: topPadding, bottomPadding: bottomPadding,
                    keepAspectRatio: keepAspectRatio, framing: framing, orientation: orientation) else {
                    // Never substitute an uncropped screen when a crop fails.
                    fail("Le cadrage ne correspond plus à l’écran. Rétablis l’orientation choisie ou règle le cadrage du TFT.")
                    return
                }
                encoder.encode(pixelBuffer: output, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
        }
    }

    override func broadcastPaused() { onWorker { paused = true } }
    override func broadcastResumed() { onWorker { paused = false } }
    override func broadcastFinished() { onWorker { tearDown() } }

    private func tearDown() {
        active = false
        encoderReady = false
        let connection = localConnection
        localConnection = nil
        connection?.cancel()
        encoder.stop()
    }

    private func fail(_ message: String) {
        guard active else { return }
        print("Diffusion arrêtée : \(message)")
        let error = NSError(domain: "com.nicolasrivet.NicoMirror", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: message])
        tearDown()
        // Notify ReplayKit after releasing its current sample-buffer callback.
        DispatchQueue.main.async { [weak self] in self?.finishBroadcastWithError(error) }
    }

    override func finishBroadcastWithError(_ error: Error) {
        onWorker { tearDown() }
        super.finishBroadcastWithError(error)
    }

    func encoderDidOutputNALUnit(data: Data) {
        worker.async { [weak self] in
            guard let self, self.active, self.encoderReady, let connection = self.localConnection else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil, self.active else { return }
                self.fail("L’envoi de la vidéo à Double Interface a échoué.")
            })
        }
    }
}
