import UIKit
import CoreMedia
import CoreVideo
import CoreLocation

/// Snapshots ONLY the miniature's native map. The main map, keyboard, sheets,
/// miniature position and application chrome are never sent by this producer.
final class WebPanelStream: H264EncoderDelegate {
    private let server: TcpServerManager
    private let encoder = H264Encoder()
    // Keep map image conversion/VideoToolbox work off the UI thread.
    // The serial queue also prevents stopping an encoder during an encode.
    private let encodingQueue = DispatchQueue(label: "DoubleInterface.TFT.encoding", qos: .userInitiated)
    private var pixelBufferPool: CVPixelBufferPool?
    private var timer: Timer?
    private var generation = 0
    private var active = false
    private var streamStartedAt: TimeInterval = 0
    private var wantsVideo = false
    private var nextEncoderAttempt: TimeInterval = 0
    private var encoderRetry: DispatchWorkItem?
    private var backgroundLocationDriven = false
    private var lockedDelivery = LockedPositionDelivery()
    private var lockedRecovery: DispatchWorkItem?
    private var snapshotPending = false
    private var pendingSince = 0.0
    private var outputSize = CGSize(width: 600, height: 1024)
    private var splash = TFTStartupSplash()
    private var splashWake: DispatchWorkItem?

    func armStartupSplash() {
        dispatchPrecondition(condition: .onQueue(.main))
        splashWake?.cancel()
        splashWake = nil
        splash.arm()
        resetLockedDelivery()
        if active {
            generation += 1
            snapshotPending = false
            WebCockpitSession.shared.cancelSnapshot()
        }
    }

    func videoFrameSent(capturedAt: TimeInterval?, sentAt: TimeInterval) -> Date? {
        splash.sentFrame(capturedAt: capturedAt, sentAt: sentAt)
        scheduleLockedSplashEnd()
        guard let fix = lockedDelivery.sent(capturedAt: capturedAt) else { return nil }
        lockedRecovery?.cancel()
        lockedRecovery = nil
        return fix
    }

    private func scheduleLockedSplashEnd() {
        guard active, backgroundLocationDriven, splashWake == nil, let deadline = splash.deadline else { return }
        let wake = DispatchWorkItem { [weak self] in
            self?.splashWake = nil
            self?.requestBackgroundLocationCapture()
        }
        splashWake = wake
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime),
                                      execute: wake)
    }

    init(server: TcpServerManager) {
        self.server = server
        encoder.delegate = self
        encoder.onError = { [weak self] status in
            DispatchQueue.main.async {
                ProjectionDiagnostics.shared.recordError("Double Interface : encodeur TFT \(status)")
                if let self, self.active, self.wantsVideo {
                    let locked = self.backgroundLocationDriven
                    self.stop()
                    self.wantsVideo = true
                    self.backgroundLocationDriven = locked
                    self.deferEncoderRetry()
                }
            }
        }
    }

    func start(backgroundLocationDriven: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        wantsVideo = true
        if active {
            if self.backgroundLocationDriven != backgroundLocationDriven {
                // GPS and foreground frames use the same video format and TCP link.
                // Keep the working encoder when iOS moves between the two modes.
                generation += 1
                snapshotPending = false
                WebCockpitSession.shared.cancelSnapshot()
                setCaptureMode(locked: backgroundLocationDriven)
            }
            return
        }
        self.backgroundLocationDriven = backgroundLocationDriven
        if ProcessInfo.processInfo.systemUptime < nextEncoderAttempt {
            scheduleEncoderRetryIfNeeded()
            return
        }
        let preset = KoveScreenPreset.current
        outputSize = CGSize(width: preset.width, height: preset.height)
        let encoderReady = encodingQueue.sync {
            preparePixelBufferPool(width: preset.width, height: preset.height)
            return encoder.start(width: Int32(preset.width), height: Int32(preset.height),
                                 fps: TFTFrameRatePolicy.targetFPS)
        }
        guard encoderReady else {
            ProjectionDiagnostics.shared.recordError("L’encodeur du TFT n’a pas démarré.")
            deferEncoderRetry()
            return
        }
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        active = true
        encoderRetry?.cancel()
        encoderRetry = nil
        nextEncoderAttempt = 0
        generation += 1
        setCaptureMode(locked: backgroundLocationDriven)
    }

    private func deferEncoderRetry() {
        nextEncoderAttempt = ProcessInfo.processInfo.systemUptime + 2
        scheduleEncoderRetryIfNeeded()
    }

    private func scheduleEncoderRetryIfNeeded() {
        guard wantsVideo, encoderRetry == nil else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.encoderRetry = nil
            guard self.wantsVideo, !self.active else { return }
            let locked = self.backgroundLocationDriven
            let state = UIApplication.shared.applicationState
            guard state == (locked ? .background : .active) else { return }
            self.start(backgroundLocationDriven: locked)
        }
        encoderRetry = retry
        let delay = max(0, nextEncoderAttempt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func setCaptureMode(locked: Bool) {
        timer?.invalidate()
        timer = nil
        resetLockedDelivery()
        backgroundLocationDriven = locked
        splashWake?.cancel()
        splashWake = nil
        if locked {
            scheduleLockedSplashEnd()
            requestBackgroundLocationCapture()
        } else {
            let timer = Timer(timeInterval: TFTFrameRatePolicy.timerInterval, repeats: true) { [weak self] _ in
                self?.capture()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            capture()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active || wantsVideo else { return }
        active = false
        splashWake?.cancel()
        splashWake = nil
        wantsVideo = false
        encoderRetry?.cancel()
        encoderRetry = nil
        nextEncoderAttempt = 0
        backgroundLocationDriven = false
        generation += 1
        snapshotPending = false
        resetLockedDelivery()
        WebCockpitSession.shared.cancelSnapshot()
        timer?.invalidate()
        timer = nil
        encodingQueue.sync {
            encoder.stop()
            pixelBufferPool = nil
        }
    }

    /// Use the most recent real fix whenever capture or transport capacity opens up.
    func requestBackgroundLocationCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard wantsVideo, backgroundLocationDriven,
              UIApplication.shared.applicationState == .background else { return }
        if !active {
            start(backgroundLocationDriven: true)
            return
        }
        capture()
    }

    private func resetLockedDelivery() {
        lockedRecovery?.cancel()
        lockedRecovery = nil
        lockedDelivery = LockedPositionDelivery()
    }

    /// Recovery only. Healthy GPS updates go straight to capture with no pacing timer.
    private func scheduleLockedRecovery(capturedAt: TimeInterval, after delay: TimeInterval) {
        lockedRecovery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lockedDelivery.isInFlight(capturedAt) else { return }
            self.lockedRecovery = nil
            self.lockedDelivery.retry(capturedAt: capturedAt)
            if self.snapshotPending {
                self.generation += 1
                self.snapshotPending = false
                WebCockpitSession.shared.cancelSnapshot()
            }
            self.requestBackgroundLocationCapture()
        }
        lockedRecovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func capture() {
        guard active else { return }
        guard UIApplication.shared.applicationState == .active || backgroundLocationDriven else { return }
        // Stop creating more encoded frames when TCP is still processing older
        // ones. This is source-side backpressure: no H.264 delta frame is dropped.
        guard server.canAcceptNewVideoFrame(maxPendingWrites: backgroundLocationDriven ? 1 : 2) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A stalled map callback must not lock the capture loop.
        if snapshotPending {
            if now - pendingSince > TFTFrameRatePolicy.snapshotTimeout {
                ProjectionDiagnostics.shared.recordError("La miniature ne fournit plus d’image.")
                generation += 1
                snapshotPending = false
                WebCockpitSession.shared.cancelSnapshot()
            }
            if snapshotPending { return }
        }
        // La même image statique est encodée en H.264 pour le TFT, sans
        // capturer l’interface entière de l’iPhone (et sans polluer la carte).
        if splash.shouldShow(at: now) {
            if !backgroundLocationDriven || splash.deadline == nil { captureSplashFrame(at: now) }
            return
        }
        // Use the encoder's exact timestamp as the socket completion identifier.
        let pts = CMTime(seconds: now, preferredTimescale: 1_000_000)
        let session = WebCockpitSession.shared
        let id = session.layout.tft
        var lockedFix: CLLocation?
        if backgroundLocationDriven {
            guard let fix = LocationAndNavigationManager.shared.userLocation,
                  ProjectionPolicy.isFresh(timestamp: fix.timestamp,
                                           accuracy: fix.horizontalAccuracy, now: Date()),
                  lockedDelivery.begin(fix: fix.timestamp, capturedAt: pts.seconds,
                                       heading: session.renderer(id).courseUpHeading) else { return }
            scheduleLockedRecovery(capturedAt: pts.seconds, after: TFTFrameRatePolicy.snapshotTimeout)
            lockedFix = fix
        }
        let nameProfile = session.profile(id)
        let revision = session.sourceRevision
        snapshotPending = true
        pendingSince = now
        let token = generation
        session.snapshotTFT(width: outputSize.width, lockedFix: lockedFix) { [weak self] image, error in
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == token else { return }
                guard session.layout.tft == id, session.sourceRevision == revision else {
                    self.snapshotPending = false
                    return
                }
                if let lockedFix, !ProjectionPolicy.isFresh(timestamp: lockedFix.timestamp,
                                                           accuracy: lockedFix.horizontalAccuracy, now: Date()) {
                    self.snapshotPending = false
                    self.lockedDelivery.retry(capturedAt: pts.seconds)
                    self.requestBackgroundLocationCapture()
                    return
                }
                guard let image else {
                    self.snapshotPending = false
                    ProjectionDiagnostics.shared.recordError(error?.localizedDescription ?? "La miniature ne fournit pas d’image.")
                    if lockedFix != nil { self.scheduleLockedRecovery(capturedAt: pts.seconds, after: 0.25) }
                    return
                }
                // Do not discard a successfully rendered locked-map image merely
                // because another GPS callback arrived in the meantime. On slow
                // raster maps this previously forced two full renders and halved
                // the update frequency. After the TCP write, capture the latest fix.
                let size = self.outputSize
                let flushImmediately = lockedFix != nil
                self.encodingQueue.async { [weak self] in
                    guard let self else { return }
                    let buffer = self.pixelBuffer(image, outputSize: size, nameProfile: nameProfile)
                    let encoded = buffer.map {
                        self.encoder.encode(pixelBuffer: $0, pts: pts, flushImmediately: flushImmediately)
                    } ?? false
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.active, self.generation == token else { return }
                        self.snapshotPending = false
                        if encoded {
                            ProjectionDiagnostics.shared.recordCaptureSubmitted()
                        } else {
                            ProjectionDiagnostics.shared.recordError("Impossible de préparer l’image TFT.")
                            if flushImmediately { self.scheduleLockedRecovery(capturedAt: pts.seconds, after: 0.25) }
                        }
                        if self.backgroundLocationDriven { self.requestBackgroundLocationCapture() }
                    }
                }
            }
        }
    }

    private func captureSplashFrame(at now: TimeInterval) {
        guard let splashImage = UIImage(named: "StartupLogoV2") else {
            ProjectionDiagnostics.shared.recordError("Visuel d’accueil TFT introuvable.")
            splash = TFTStartupSplash()
            return
        }
        snapshotPending = true
        pendingSince = now
        let token = generation
        let size = outputSize
        let pts = CMTime(seconds: now, preferredTimescale: 1_000_000)
        let forceKeyframe = splash.deadline == nil
        let flushImmediately = backgroundLocationDriven
        splash.submittedLogo(at: pts.seconds)
        encodingQueue.async { [weak self] in
            guard let self else { return }
            let buffer = self.pixelBuffer(splashImage, outputSize: size,
                                          nameProfile: nil, isSplash: true)
            let encoded = buffer.map { self.encoder.encode(pixelBuffer: $0, pts: pts,
                                                          forceKeyframe: forceKeyframe,
                                                          flushImmediately: flushImmediately) } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == token else { return }
                self.snapshotPending = false
                if encoded {
                    ProjectionDiagnostics.shared.recordCaptureSubmitted()
                } else {
                    ProjectionDiagnostics.shared.recordError("Logo initial TFT indisponible.")
                }
            }
        }
    }

    /// Reuse allocated surfaces instead of reallocating a 600x1024 bitmap every frame.
    /// These methods are called exclusively on encodingQueue.
    private func preparePixelBufferPool(width: Int, height: Int) {
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA as CFNumber,
            kCVPixelBufferWidthKey: width as CFNumber,
            kCVPixelBufferHeightKey: height as CFNumber,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                                             imageAttributes as CFDictionary, &pixelBufferPool)
        if result != kCVReturnSuccess { pixelBufferPool = nil }
    }

    private func pixelBuffer(_ image: UIImage, outputSize: CGSize,
                             nameProfile: WebMapProfile?, isSplash: Bool = false) -> CVPixelBuffer? {
        let width = Int(outputSize.width), height = Int(outputSize.height)
        guard width > 0, height > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let status: CVReturn
        if let pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer)
        } else {
            let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attrs, &buffer)
        }
        guard status == kCVReturnSuccess, let buffer else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let background = isSplash
            ? UIColor(red: 0.027, green: 0.075, blue: 0.122, alpha: 1)
            : UIColor.black
        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: outputSize))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let top = CGFloat(KoveScreenPreset.topPadding)
        let available = max(10, CGFloat(height) - top - CGFloat(KoveScreenPreset.bottomPadding))
        let rect: CGRect
        if isSplash {
            // Ajustement entier : ne jamais rogner le logo, contrairement aux
            // cartes qui remplissent le TFT par recadrage.
            let scale = min(CGFloat(width) * 0.82 / image.size.width,
                            CGFloat(height) * 0.82 / image.size.height)
            rect = CGRect(x: (CGFloat(width) - image.size.width * scale) / 2,
                          y: (CGFloat(height) - image.size.height * scale) / 2,
                          width: image.size.width * scale, height: image.size.height * scale)
        } else {
            // Les cartes occupent leur taille habituelle, sans modification.
            let scale = max(CGFloat(width) / image.size.width, available / image.size.height)
            rect = CGRect(x: (CGFloat(width) - image.size.width * scale) / 2,
                          y: top + (available - image.size.height * scale) / 2,
                          width: image.size.width * scale, height: image.size.height * scale)
        }
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        // Le TFT ne diffuse PAS l'overlay SwiftUI de l'iPhone : écrire le nom
        // directement dans le même buffer vidéo H.264, sans refaire une image.
        // La sélection de la carte est figée AVANT la capture asynchrone.
        if let nameProfile, !isSplash {
            let fontSize = min(36, CGFloat(width) * 0.065)
            (nameProfile.overlayTitle as NSString).draw(
                at: CGPoint(x: 18, y: top + 18),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                    .foregroundColor: nameProfile.overlayColor
                ])
        }
        UIGraphicsPopContext()
        return buffer
    }

    nonisolated func encoderDidOutputNALUnit(data: Data) {
        encoderDidOutputNALUnit(data: data, pts: .invalid)
    }

    nonisolated func encoderDidOutputNALUnit(data: Data, pts: CMTime) {
        let timestamp = pts.seconds
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, !timestamp.isFinite || timestamp >= self.streamStartedAt,
                  self.splash.acceptsFrame(at: timestamp) else { return }
            // The socket now owns this frame. Only its write or a connection reset
            // can release it, even if the Wi-Fi stalls beyond the render timeout.
            if self.lockedDelivery.isInFlight(timestamp) {
                self.lockedRecovery?.cancel()
                self.lockedRecovery = nil
            }
            ProjectionDiagnostics.shared.recordEncodedFrame()
            self.server.streamVideoFrame(data: data, source: .screen,
                                         capturedAt: timestamp.isFinite ? timestamp : nil)
        }
    }
}
