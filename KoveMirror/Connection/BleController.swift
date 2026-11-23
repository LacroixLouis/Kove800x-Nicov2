import Foundation
import CoreBluetooth
import Combine
import CoreLocation
import UIKit

enum BleState: String {
    case disconnected = "Disconnected"
    case scanning = "Scanning..."
    case connecting = "Connecting..."
    case connected = "Connected & Active"
}

class BleController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static weak var shared: BleController?
    
    @Published var connectionState: BleState = .disconnected
    @Published var logMessages: [String] = []
    @Published var connectedDeviceName: String? = nil
    @Published var isStreaming = false
    @Published private(set) var isTFTControlConnected = false
    private var tftSessionRequested = true
    private var manualDisconnectRequested = false
    // A temporary Wi-Fi/BLE interruption must not stop the GPS in the middle
    // of a deliberately started locked TFT ride.
    private var hasStartedTFTRide = false
    private var retryAfterCancellation = false
    @Published private(set) var bluetoothError: String?
    private var automaticConnectionEnabled: Bool {
        UserDefaults.standard.object(forKey: TFTConnectionPolicy.automaticKey) as? Bool ?? true
    }

    var hasTFTConnection: Bool {
        connectionState == .connected || isTFTControlConnected || isStreaming
    }

    private var savedPeripheralIdentifier: UUID? {
        let value = UserDefaults.standard.string(forKey: "last_ble_uuid")
            ?? UserDefaults(suiteName: appGroupSuiteName)?.string(forKey: "last_ble_uuid")
        return value.flatMap { UUID(uuidString: $0) }
    }

    var hasSavedMotorcycle: Bool { savedPeripheralIdentifier != nil }
    var savedMotorcycleName: String { UserDefaults.standard.string(forKey: "last_ble_name") ?? "Compteur mémorisé" }

    func resumeAutomaticConnection() {
        guard automaticConnectionEnabled, !manualDisconnectRequested else { return }
        resumeConnection()
    }

    /// Reuse live transports and pending BLE attempts when selecting another app.
    func resumeConnection() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.resumeConnection() }
            return
        }
        guard !isPreview else { return }
        startTcpServers()
        guard !isStreaming else { return }
        if connectionState == .connected {
            if hasSentHandshake { startMirroring() }
        } else if connectionState != .scanning {
            if !reconnectSavedPeripheralIfAvailable() { startScanning() }
        }
        reconnectWiFiIfNeeded()
    }

    /// The user asked to retry: cancel a pending BLE attempt before scanning
    /// again. Calling resumeConnection alone retains a non-expiring attempt.
    func retryConnection(forgetSavedMotorcycle: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isPreview else { return }
        if forgetSavedMotorcycle {
            for key in ["last_ble_uuid", "last_ble_name"] {
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults(suiteName: appGroupSuiteName)?.removeObject(forKey: key)
            }
        }
        startTcpServers()
        if !forgetSavedMotorcycle && isStreaming {
            resumeConnection()
            return
        }
        if !isTFTControlConnected && !isStreaming && MotorcycleWiFiManager.shared.hasSavedNetwork {
            MotorcycleWiFiManager.shared.retrySavedNetwork()
        }
        reconnectWiFiIfNeeded()
        guard let centralManager, centralManager.state == .poweredOn else { return }
        guard !retryAfterCancellation else { return }
        if let peripheral = targetPeripheral {
            if peripheral.state == .connected && !forgetSavedMotorcycle {
                if hasSentHandshake { startMirroring() }
                else { peripheral.discoverServices(nil) }
                return
            }
            if peripheral.state != .disconnected {
                retryAfterCancellation = true
                log("🔄 Annulation de la tentative Bluetooth avant une nouvelle recherche…")
                // The delegate callback completes the reset, so an old
                // cancellation cannot tear down a newly discovered session.
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
        }
        targetPeripheral = nil
        startScanning()
    }

    private func refreshConnectionMaintenance() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshConnectionMaintenance() }
            return
        }
        guard !isPreview else { return }
        let enabled = UserDefaults.standard.object(forKey: TFTConnectionPolicy.lockedKey) as? Bool ?? true
        let transportReady = connectionState == .connected || isTFTControlConnected || isStreaming
        if transportReady && isWebPanelProjectionActive && !isPhoneScreenSelected && tftSessionRequested {
            hasStartedTFTRide = true
        }
        // Keep background CoreLocation active while reconnecting the TFT, but
        // not for ordinary app browsing or when the phone screen was selected.
        let keep = tftSessionRequested && enabled && !manualDisconnectRequested
            && isWebPanelProjectionActive && !isPhoneScreenSelected
            && (transportReady || hasStartedTFTRide)
        if keep { BackgroundKeepAliveManager.shared.start() }
        else { BackgroundKeepAliveManager.shared.stop() }
        if UIApplication.shared.applicationState == .background {
            if enabled && isWebPanelProjectionActive && !isPhoneScreenSelected && !manualDisconnectRequested
                && LocationAndNavigationManager.shared.hasActiveBackgroundRide {
                ProjectionDiagnostics.shared.beginLockedRide()
            } else {
                ProjectionDiagnostics.shared.finishLockedRide()
            }
        }
        ProjectionDiagnostics.shared.setTransports(bluetooth: connectionState == .connected,
            control: isTFTControlConnected, video: isStreaming)
    }
    
    @Published var isBroadcasting = false
    @Published var isBluetoothPoweredOff = false
    @Published var odoDistanceKm: Double? = nil
    @Published var tripDistanceKm: Double? = nil
    @Published private(set) var motorcycleOdometer: MotorcycleOdometer?
    @Published private(set) var mileageSyncMessage: String?
    @Published var lastClockSyncDate: Date? = nil
    
    private var cancellables = Set<AnyCancellable>()
    @Published private(set) var projectionMode: ProjectionMode = .disconnected
    @Published private(set) var isWebPanelProjectionActive = false
    @Published private(set) var isPhoneScreenSelected = UserDefaults.standard.bool(forKey: "doubleInterface.phoneScreenSelected")

    func selectPhoneScreen() {
        dispatchPrecondition(condition: .onQueue(.main))
        isPhoneScreenSelected = true
        UserDefaults.standard.set(true, forKey: "doubleInterface.phoneScreenSelected")
        KoveScreenPreset.broadcastFraming = .fullScreen
        KoveScreenPreset.keepAspectRatio = true
        // Bring up the loopback receiver as well as reusing the motorcycle link.
        resumeConnection()
        refreshProjectionMode(force: true)
        refreshConnectionMaintenance()
    }

    func selectMiniature() {
        dispatchPrecondition(condition: .onQueue(.main))
        isPhoneScreenSelected = false
        UserDefaults.standard.set(false, forKey: "doubleInterface.phoneScreenSelected")
        refreshProjectionMode(force: true)
        refreshConnectionMaintenance()
    }

    func beginWebPanelProjection() {
        if !isWebPanelProjectionActive && isStreaming && !isPhoneScreenSelected {
            webPanelStream.armStartupSplash()
        }
        isWebPanelProjectionActive = true
        // Display choices work before the bike is connected. Only Connexion
        // starts/retries its setup; an existing video link is reused here.
        refreshProjectionMode(force: true)
        refreshConnectionMaintenance()
    }

    func endWebPanelProjection() {
        guard isWebPanelProjectionActive else { return }
        isWebPanelProjectionActive = false
        hasStartedTFTRide = false
        refreshProjectionMode(force: true)
        refreshConnectionMaintenance()
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.publisher(for: MotorcycleWiFiManager.configurationAccepted)
            .sink { [weak self] _ in
                guard let self, self.tftSessionRequested, !self.manualDisconnectRequested else { return }
                // The TFT may have missed projection activation before the
                // phone joined its Wi-Fi. Re-arm without closing live sockets.
                self.resumeConnection()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .webPanelSourceChanged)
            .sink { [weak self] _ in
                guard let self, self.isWebPanelProjectionActive else { return }
                // Drain the previous source and restart the encoder at a keyframe.
                // BLE and TCP connections stay open during the exchange.
                self.refreshProjectionMode(force: true)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.refreshConnectionMaintenance()
                self?.refreshProjectionMode()
                self?.log("🔒 Arrière-plan : les liaisons TFT existantes restent ouvertes.")
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { _ in ProjectionDiagnostics.shared.finishLockedRide() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .nicoNavigationUpdated)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshProjectionMode()
                // On a locked ride the foreground timer is suspended by iOS.
                // Try one TFT-only image on genuine GPS updates instead.
                if self.projectionMode == .navigation {
                    self.webPanelStream.requestBackgroundLocationCapture()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.refreshProjectionMode()
                self?.refreshConnectionMaintenance()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshProjectionMode(force: true)
                self.refreshConnectionMaintenance()
                if self.automaticConnectionEnabled && !self.manualDisconnectRequested {
                    self.resumeConnection()
                }
                guard self.connectionState == .connected else { return }
                self.log("📱 App became active while connected to motorcycle. Syncing clock time...")
                self.syncTime()
                self.requestMileage()
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in
                guard let self = self, self.connectionState == .connected else { return }
                self.log("🕒 Time zone changed. Updating motorcycle clock time...")
                self.syncTime()
            }
            .store(in: &cancellables)
    }
    
    /// All video producers switch through this single main-thread coordinator.
    private func refreshProjectionMode(force: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshProjectionMode(force: force) }
            return
        }
        let enabled = UserDefaults.standard.object(forKey: TFTConnectionPolicy.lockedKey) as? Bool ?? true
        let desired = ProjectionPolicy.dualPanelMode(
            connected: isStreaming, foreground: UIApplication.shared.applicationState != .background,
            cockpitVisible: isWebPanelProjectionActive,
            phoneScreenSelected: isPhoneScreenSelected, broadcasting: isBroadcasting,
            lockedRideEnabled: enabled,
            rideActive: LocationAndNavigationManager.shared.hasActiveBackgroundRide)
        let modeChanged = desired != projectionMode
        guard force || modeChanged else { return }
        let wasMapStream = projectionMode == .screen || projectionMode == .navigation
        let isMapStream = desired == .screen || desired == .navigation
        if !isMapStream || !wasMapStream || (force && !modeChanged) { webPanelStream.stop() }
        projectionMode = desired
        WebCockpitSession.shared.setLockedTFTOnly(desired == .navigation)
        ProjectionDiagnostics.shared.setMode(desired)
        if modeChanged { log("📽️ " + desired.rawValue) }
        if desired == .screen || desired == .navigation {
            tcpServerManager.selectVideoSource(.screen)
            webPanelStream.start(backgroundLocationDriven: desired == .navigation)
        } else if desired == .broadcast {
            tcpServerManager.selectVideoSource(.broadcast)
        } else {
            // A stopped broadcast cannot fall back to the miniature, nor may
            // the miniature switch to whole-phone sharing without selection.
            tcpServerManager.selectVideoSource(.paused)
        }
    }

    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private let tcpServerManager = TcpServerManager()
    private lazy var webPanelStream = WebPanelStream(server: tcpServerManager)
    
    // Service and Characteristic UUIDs matching the ThinkerRide / Kove protocol across models
    let serviceUUID = CBUUID(string: "0000e0ff-3c17-d293-8e48-14fe2e4da212")
    let allSupportedServiceUUIDs = [
        CBUUID(string: "0000e0ff-3c17-d293-8e48-14fe2e4da212"),
        CBUUID(string: "0000e0ff-3c17-d293-8e48-14fe2e4da213"),
        CBUUID(string: "0000e0ff-3e17-d293-8e48-14fe2e4da212"),
        CBUUID(string: "0000e0ff-4017-d293-8e48-14fe2e4da212")
    ]
    let writeCharUUID = CBUUID(string: "0000ffe1-0000-1000-8000-00805f9b34fb")
    let notifyCharUUID = CBUUID(string: "0000ffe2-0000-1000-8000-00805f9b34fb")
    
    private var heartbeatTimer: Timer?
    private var mileageTimer: Timer?
    private var hasSentHandshake = false
    private var appGroupSuiteName: String { KoveScreenPreset.appGroupSuiteName }
    
    private let logQueue = DispatchQueue(label: "com.kove.mirror.log", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    private let queueAccessQueue = DispatchQueue(label: "com.kove.mirror.bleWriteQueue")
    private var bleWriteQueue: [Data] = []
    private var isWritingPackets = false
    private var bleSequenceNumber: UInt16 = 0
    private var hasLoggedMaxWriteLen: Bool = false
    private var rxBuffer: String = ""
    
    private var logFilePath: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("KoveMirror.log")
    }
    
    private func checkLogFileSizeLimit() {
        let path = logFilePath.path
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        if FileManager.default.fileExists(atPath: path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let fileSize = attrs[.size] as? UInt64,
           fileSize > 5 * 1024 * 1024 { // 5 MB limit
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    
    private func writeToLogFile(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "enableFileLogging") else { return }
        
        let lineWithNewline = line + "\n"
        if let data = lineWithNewline.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFilePath.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFilePath) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFilePath, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
    
    let isPreview: Bool
    
    override init() {
        self.isPreview = false
        super.init()
        BleController.shared = self
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "KoveMirrorRestoreID"])
        setupLocalConnectionCallback()
        setupLifecycleObservers()
        checkLogFileSizeLimit()
    }
    
    init(isPreview: Bool) {
        self.isPreview = isPreview
        super.init()
        if !isPreview {
            BleController.shared = self
            centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "KoveMirrorRestoreID"])
                setupLocalConnectionCallback()
                setupLifecycleObservers()
            checkLogFileSizeLimit()
            HandlebarKeyManager.shared.logCallback = { [weak self] msg in
                self?.log(msg)
            }
        }
    }
    
    private func setupLocalConnectionCallback() {
        self.tcpServerManager.onLocalConnectionChanged = { [weak self] isConnected in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isBroadcasting = isConnected
                self.refreshProjectionMode()
            }
        }
    }
    
    func log(_ message: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = "[\(timestamp)] \(message)"
            
            self.writeToLogFile(logLine)
            
            DispatchQueue.main.async {
                self.logMessages.insert(logLine, at: 0)
                if self.logMessages.count > 100 {
                    self.logMessages.removeLast()
                }
            }
        }
        print("BLE: \(message)")
    }
    
    func startTcpServers() {
        guard !isPreview else { return }
        tftSessionRequested = true
        manualDisconnectRequested = false
        let preset = KoveScreenPreset.current
        log("🔌 Starting TCP Servers for \(preset.displayName)...")
        
        tcpServerManager.onLog = { [weak self] msg in
            self?.log(msg)
        }
        
        tcpServerManager.onVideoBytesSent = { [weak self] count, capturedAt in
            let sentAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }
                let fix = self.webPanelStream.videoFrameSent(capturedAt: capturedAt, sentAt: sentAt)
                ProjectionDiagnostics.shared.recordSentBytes(count, capturedAt: capturedAt,
                                                            sentAt: sentAt, fixTimestamp: fix)
                if self.projectionMode == .navigation { self.webPanelStream.requestBackgroundLocationCapture() }
            }
        }
        tcpServerManager.onVideoError = { error in
            ProjectionDiagnostics.shared.recordError(error)
        }
        tcpServerManager.onVideoConnectionChanged = { [weak self] connected in
            guard !connected else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStreaming = false
                self.refreshProjectionMode(force: true)
                self.refreshConnectionMaintenance()
            }
        }
        tcpServerManager.onControlConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isTFTControlConnected = connected
                self.refreshConnectionMaintenance()
            }
        }
        tcpServerManager.onControlPacketReceived = { text in
            ProjectionDiagnostics.shared.recordControlPacket()
            HandlebarKeyManager.shared.processJsonText(text)
        }
        
        tcpServerManager.onControlHandshakeCompleted = { [weak self] in
            DispatchQueue.main.async {
            guard let self, self.tftSessionRequested else { return }
            self.log("🔌 TCP Control channel active (port 17818). Triggering screen projection...")
            if !self.isStreaming {
                self.startMirroring()
            }
            if self.odoDistanceKm == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, self.connectionState == .connected, self.odoDistanceKm == nil else { return }
                    self.requestMileage()
                }
            }
            }
        }
        
        tcpServerManager.startServers(width: preset.width, height: preset.height) { [weak self] in
            guard let self = self else { return }
            self.log("📺 TCP Video stream connected.")
            DispatchQueue.main.async {
                // Chaque nouvelle connexion vidéo du compteur affiche le même
                // StartupLogoV2 durant 3 s AVANT de reprendre la carte TFT.
                self.webPanelStream.armStartupSplash()
                self.isStreaming = true
                self.refreshConnectionMaintenance()
                self.refreshProjectionMode(force: true)
            }
        }
        refreshConnectionMaintenance()
    }

    private func reconnectWiFiIfNeeded() {
        // A previously stored Wi-Fi network must be rejoined even if Bluetooth
        // has not finished discovering the TFT yet. These are independent links.
        // An active control/video socket is stronger evidence of a usable
        // transport than a successful HotspotConfiguration completion.
        guard tftSessionRequested, !manualDisconnectRequested,
              !isTFTControlConnected, !isStreaming else { return }
        MotorcycleWiFiManager.shared.resumeSavedNetwork()
    }
    
    func startScanning() {
        guard !isPreview, let centralManager = centralManager, centralManager.state == .poweredOn else {
            log("⚠️ Bluetooth is not powered on.")
            return
        }
        
        manualDisconnectRequested = false
        if targetPeripheral?.state == .connected || targetPeripheral?.state == .connecting { return }
        connectionState = .scanning
        let isBackground = (UIApplication.shared.applicationState == .background)
        log("🔍 Scanning for Kove TFT devices (background: \(isBackground))...")
        // iOS requires non-nil service UUID array when scanning in the background.
        // In foreground, we scan for nil to catch devices advertising by name.
        let servicesToScan = isBackground ? allSupportedServiceUUIDs : nil
        centralManager.scanForPeripherals(withServices: servicesToScan, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    @discardableResult
    func reconnectSavedPeripheralIfAvailable() -> Bool {
        guard !isPreview, let centralManager, centralManager.state == .poweredOn else { return false }
        if retryAfterCancellation { return true }
        // Do not issue another connect or restart discovery for a live session.
        if let targetPeripheral {
            if targetPeripheral.state == .connecting {
                connectionState = .connecting
                return true
            }
            if targetPeripheral.state == .connected && hasSentHandshake {
                connectionState = .connected
                connectedDeviceName = targetPeripheral.name
                return true
            }
        }
        guard let uuid = savedPeripheralIdentifier else {
            return false
        }
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let savedPeripheral = peripherals.first else {
            return false
        }
        
        targetPeripheral = savedPeripheral
        savedPeripheral.delegate = self

        if savedPeripheral.state == .connecting {
            connectionState = .connecting
            return true
        }
        
        if savedPeripheral.state == .connected {
            log("🔄 Reusing already connected device: \(savedPeripheral.name ?? "TFT Device")")
            connectionState = .connected
            connectedDeviceName = savedPeripheral.name
            hasSentHandshake = false
            savedPeripheral.discoverServices(nil)
            return true
        } else {
            log("⏳ Waiting / auto-connecting to known motorcycle: \(savedPeripheral.name ?? "TFT Device")...")
            connectionState = .connecting
            centralManager.connect(savedPeripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
            return true
        }
    }
    
    func disconnect() {
        hasStartedTFTRide = false
        manualDisconnectRequested = true
        retryAfterCancellation = false
        tftSessionRequested = false
        centralManager?.stopScan()
        rxBuffer = ""
        clearWriteQueue(resetSequence: true)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        mileageTimer?.invalidate()
        mileageTimer = nil
        connectedDeviceName = nil
        odoDistanceKm = nil
        tripDistanceKm = nil
        motorcycleOdometer = nil
        mileageSyncMessage = nil
        lastClockSyncDate = nil
        TelemetrySyncManager.shared.stopSync()
        NavigationSyncManager.shared.stopSync()
        
        log("🎬 Stopping screen capture...")
        isStreaming = false
        refreshProjectionMode(force: true)
        BackgroundKeepAliveManager.shared.stop()
        
        log("🔌 Stopping TCP Servers in main app...")
        tcpServerManager.stop()
        
        if let peripheral = targetPeripheral {
            log("🔴 Disconnecting from \(peripheral.name ?? "TFT Device")...")
            centralManager?.cancelPeripheralConnection(peripheral)
        } else {
            connectionState = .disconnected
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !isPreview else { return }
        switch central.state {
        case .poweredOn:
            isBluetoothPoweredOff = false
            bluetoothError = nil
            log("🟢 Bluetooth is ON.")
            // If the saved peripheral is known, initiate non-expiring background connection
            guard automaticConnectionEnabled, !manualDisconnectRequested else { return }
            if !reconnectSavedPeripheralIfAvailable() { startScanning() }
        case .poweredOff:
            isBluetoothPoweredOff = true
            retryAfterCancellation = false
            log("🔴 Bluetooth is OFF.")
            connectionState = .disconnected
            refreshConnectionMaintenance()
        case .unauthorized:
            isBluetoothPoweredOff = false
            retryAfterCancellation = false
            bluetoothError = "Autorise le Bluetooth pour Double Interface dans les réglages de l’iPhone."
            log("🚫 Bluetooth permission is unauthorized.")
            connectionState = .disconnected
            refreshConnectionMaintenance()
        default:
            retryAfterCancellation = false
            log("⚠️ Bluetooth state changed: \(central.state.rawValue)")
            connectionState = .disconnected
        }
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        log("🔄 Restoring Bluetooth Central state from iOS background wake...")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restoredPeripheral = peripherals.first {
            log("🔄 Restored connection state for \(restoredPeripheral.name ?? "Device") (state: \(restoredPeripheral.state.rawValue))")
            targetPeripheral = restoredPeripheral
            restoredPeripheral.delegate = self
            if restoredPeripheral.state == .connected {
                connectionState = .connected
                connectedDeviceName = restoredPeripheral.name
                restoredPeripheral.discoverServices(nil)
            } else {
                connectionState = .connecting
                centralManager?.connect(restoredPeripheral, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard !manualDisconnectRequested, !retryAfterCancellation,
              targetPeripheral?.state != .connected,
              targetPeripheral?.state != .connecting else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        
        let isKoveDevice = name.uppercased().contains("CQKY") ||
                           name.uppercased().contains("KOVE") ||
                           name.uppercased().contains("THINKER") ||
                           name.uppercased().contains("TFT") ||
                           name.uppercased().contains("ZFBT") ||
                           advertisedServices.contains(where: { allSupportedServiceUUIDs.contains($0) })
        
        guard isKoveDevice else { return }
        // Never silently associate a different nearby motorcycle.
        if let saved = savedPeripheralIdentifier, saved != peripheral.identifier { return }
        
        let displayName = name.isEmpty ? "Kove TFT Device" : name
        log("📱 Discovered peripheral: \(displayName) [RSSI: \(RSSI)]")
        targetPeripheral = peripheral
        
        // Remember the motorcycle only after didConnect confirms the link.
        connectionState = .connecting
        centralManager?.stopScan()
        log("🔌 Connecting to \(displayName)...")
        centralManager?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !retryAfterCancellation, !manualDisconnectRequested else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("✅ Connected to \(peripheral.name ?? "TFT Device"). Discovering services...")
        connectionState = .connected
        connectedDeviceName = peripheral.name
        central.stopScan()
        if automaticConnectionEnabled && !manualDisconnectRequested { startTcpServers() }
        refreshConnectionMaintenance()
        reconnectWiFiIfNeeded()
        rxBuffer = ""
        hasSentHandshake = false
        clearWriteQueue(resetSequence: false)
        peripheral.delegate = self
        
        // Save UUID to App Groups & standard UserDefaults
        if let suite = UserDefaults(suiteName: appGroupSuiteName) {
            suite.set(peripheral.identifier.uuidString, forKey: "last_ble_uuid")
            suite.synchronize()
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "last_ble_uuid")
        UserDefaults.standard.set(peripheral.name ?? "Compteur Kove", forKey: "last_ble_name")
        
        // Request background execution time from iOS to allow handshake, TCP bringup & telemetry sync
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "KoveBleConnectionWakeTask") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard targetPeripheral?.identifier == peripheral.identifier else { return }
        log("❌ Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        let retryRequested = retryAfterCancellation
        retryAfterCancellation = false
        targetPeripheral = nil
        connectionState = .disconnected
        if (retryRequested || automaticConnectionEnabled) && !manualDisconnectRequested { startScanning() }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard targetPeripheral?.identifier == peripheral.identifier else { return }
        let retryRequested = retryAfterCancellation
        retryAfterCancellation = false
        rxBuffer = ""
        clearWriteQueue(resetSequence: false)
        hasSentHandshake = false
        odoDistanceKm = nil
        tripDistanceKm = nil
        motorcycleOdometer = nil
        mileageSyncMessage = nil
        lastClockSyncDate = nil
        TelemetrySyncManager.shared.stopSync()
        NavigationSyncManager.shared.stopSync()
        log("🔴 Disconnected: \(error?.localizedDescription ?? "Clean disconnect"). Waiting for motorcycle BLE reconnection...")
        connectionState = .disconnected
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        mileageTimer?.invalidate()
        mileageTimer = nil
        writeCharacteristic = nil
        connectedDeviceName = nil
        
        // A BLE timeout does not mean the TFT's Wi-Fi or video socket has failed.
        log("🔄 BLE perdu : les canaux Wi-Fi actifs sont conservés pendant la reconnexion.")
        refreshConnectionMaintenance()
        if retryRequested && !manualDisconnectRequested {
            targetPeripheral = nil
            startScanning()
            return
        }
        guard automaticConnectionEnabled, !manualDisconnectRequested else { return }

        // Keep a single pending connection to the saved peripheral; do not scan
        // for a different bike while iOS is waiting for this one to reappear.
        connectionState = .connecting
        centralManager?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
        
    }
    
    // MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("❌ Service discovery error: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services, !services.isEmpty else {
            log("❌ No GATT services found on device.")
            return
        }
        
        // Match against known ThinkerRide / Kove service UUIDs
        if let matchedService = services.first(where: { allSupportedServiceUUIDs.contains($0.uuid) }) {
            log("🔓 Discovered NicoMirroring Service (\(matchedService.uuid)). Discovering characteristics...")
            peripheral.discoverCharacteristics([writeCharUUID, notifyCharUUID], for: matchedService)
            return
        }
        
        // Discover ALL characteristics across services
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("❌ Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            if char.uuid == writeCharUUID {
                writeCharacteristic = char
                log("📝 Write Characteristic ready (\(char.uuid.uuidString)).")
            } else if writeCharacteristic == nil && (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)) {
                writeCharacteristic = char
                log("📝 Fallback Write Characteristic ready (\(char.uuid.uuidString)).")
            }
        }
        
        // Subscribe ONLY to the dedicated notification characteristic (FFE2).
        // Avoid subscribing to binary debug streams (such as FFE3) which causes JSON receive buffer corruption.
        if let exactNotify = characteristics.first(where: { $0.uuid == notifyCharUUID }) {
            if exactNotify.isNotifying {
                log("🔔 Notification already active on Characteristic (\(exactNotify.uuid.uuidString)).")
                if writeCharacteristic != nil && !hasSentHandshake {
                    hasSentHandshake = true
                    sendInitHandshake()
                    startHeartbeat()
                    startMileageTimer()
                }
            } else {
                peripheral.setNotifyValue(true, for: exactNotify)
                log("🔔 Enabling notifications on Characteristic (\(exactNotify.uuid.uuidString))...")
            }
        } else {
            for char in characteristics where char.properties.contains(.notify) || char.properties.contains(.indicate) {
                if char.isNotifying {
                    log("🔔 Notification already active on Fallback Characteristic (\(char.uuid.uuidString)).")
                    if writeCharacteristic != nil && !hasSentHandshake {
                        hasSentHandshake = true
                        sendInitHandshake()
                        startHeartbeat()
                        startMileageTimer()
                    }
                } else {
                    peripheral.setNotifyValue(true, for: char)
                    log("🔔 Enabling notifications on Fallback Characteristic (\(char.uuid.uuidString))...")
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("❌ Notification state update error: \(error.localizedDescription)")
            return
        }
        
        if characteristic.isNotifying {
            log("✅ BLE Notification active on \(characteristic.uuid.uuidString)!")
            if writeCharacteristic != nil && !hasSentHandshake {
                hasSentHandshake = true
                sendInitHandshake()
                startHeartbeat()
                startMileageTimer()
            }
        }
    }
    
    /// Frames a JSON string into 104-byte binary packets expected by the Kove TFT MCU.
    /// Framing algorithm (from KoveGo KoveService.java and TinkerAPP WriteThread.java / ByteUtils.java):
    /// - Payload = UTF-8(jsonString) + 2 checksum bytes + 0x00 (null terminator)
    /// - Checksum = sum of all bytes in UTF-8(jsonString) modulo 256, split into two nibbles with 0x80 bit set:
    ///     chk0 = ((sum >> 4) & 0x0F) | 0x80
    ///     chk1 = (sum & 0x0F) | 0x80
    /// - Chunking: payload is partitioned into slices of up to 100 bytes each.
    /// - Each frame is fixed 104 bytes:
    ///     frame[0] = 0xFE (Packet start delimiter)
    ///     frame[1] = (seq >> 8) & 0xFF (Sequence counter MSB)
    ///     frame[2] = seq & 0xFF (Sequence counter LSB)
    ///     frame[3 ..< 3 + chunkSize] = payload slice
    ///     frame[chunkSize + 3] = 0xFF (Packet end delimiter)
    ///     frame[(chunkSize + 4) ..< 104] = 0x00 (Zero padding)
    func frameJsonPacket(_ jsonString: String) -> [Data] {
        guard let jsonBytes = jsonString.data(using: .utf8) else { return [] }
        
        var sum: UInt32 = 0
        for byte in jsonBytes {
            sum = (sum + UInt32(byte)) & 0xFF
        }
        let chk0 = UInt8(((sum >> 4) & 0x0F) | 0x80)
        let chk1 = UInt8((sum & 0x0F) | 0x80)
        
        var payload = Data()
        payload.reserveCapacity(jsonBytes.count + 3)
        payload.append(jsonBytes)
        payload.append(chk0)
        payload.append(chk1)
        payload.append(0x00)
        
        var frames: [Data] = []
        var offset = 0
        let totalLength = payload.count
        
        while offset < totalLength {
            let chunkSize = min(totalLength - offset, 100)
            var frame = Data(count: 104)
            
            let seq = bleSequenceNumber
            bleSequenceNumber = (bleSequenceNumber &+ 1) & 0xFFFF
            
            frame[0] = 0xFE
            frame[1] = UInt8((seq >> 8) & 0xFF)
            frame[2] = UInt8(seq & 0xFF)
            
            let slice = payload.subdata(in: offset ..< (offset + chunkSize))
            frame.replaceSubrange(3 ..< (3 + chunkSize), with: slice)
            frame[chunkSize + 3] = 0xFF
            
            frames.append(frame)
            offset += chunkSize
        }
        
        return frames
    }
    
    private func writeString(_ str: String) {
        queueAccessQueue.async { [weak self] in
            guard let self = self else { return }
            let frames = self.frameJsonPacket(str)
            guard !frames.isEmpty else { return }
            
            self.bleWriteQueue.append(contentsOf: frames)
            self.log("📤 BLE Send JSON (\(frames.count) frame\(frames.count == 1 ? "" : "s")): \(str)")
            
            if !self.isWritingPackets {
                self.isWritingPackets = true
                self.processNextWriteItem()
            }
        }
    }
    
    private func processNextWriteItem() {
        queueAccessQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard !self.bleWriteQueue.isEmpty else {
                self.isWritingPackets = false
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let peripheral = self.targetPeripheral,
                      let char = self.writeCharacteristic else {
                    self?.queueAccessQueue.async {
                        self?.isWritingPackets = false
                    }
                    return
                }
                
                let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                
                // Flow control: If writing without response and CoreBluetooth transmit buffer is full,
                // do NOT drop packets! Suspend transmission and wait for peripheralIsReady(toSendWriteWithoutResponse:).
                if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                    self.log("⏳ BLE tx buffer full, pausing until peripheralIsReady...")
                    self.queueAccessQueue.async {
                        self.isWritingPackets = false
                    }
                    return
                }
                
                self.queueAccessQueue.async { [weak self] in
                    guard let self = self, !self.bleWriteQueue.isEmpty else {
                        self?.isWritingPackets = false
                        return
                    }
                    
                    let data = self.bleWriteQueue.removeFirst()
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        let maxLen = peripheral.maximumWriteValueLength(for: writeType)
                        if !self.hasLoggedMaxWriteLen {
                            self.hasLoggedMaxWriteLen = true
                            self.log("ℹ️ BLE Max Write Length: \(maxLen) bytes (Packet frame size: \(data.count) bytes)")
                        }
                        if data.count <= maxLen {
                            peripheral.writeValue(data, for: char, type: writeType)
                        } else {
                            var offset = 0
                            while offset < data.count {
                                let chunkLen = min(data.count - offset, maxLen)
                                let slice = data.subdata(in: offset ..< (offset + chunkLen))
                                peripheral.writeValue(slice, for: char, type: writeType)
                                offset += chunkLen
                            }
                        }
                        
                        if writeType == .withoutResponse {
                            // 120ms pacing delay (matching ThinkerRide / Android 150ms pacing)
                            // to prevent motorcycle MCU UART ring buffer overflow
                            self.queueAccessQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                                self?.processNextWriteItem()
                            }
                        }
                        // For .withResponse, processNextWriteItem is resumed in peripheral(_:didWriteValueFor:error:)
                    }
                }
            }
        }
    }
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        log("🔄 BLE ready to send writes without response.")
        queueAccessQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isWritingPackets && !self.bleWriteQueue.isEmpty {
                self.isWritingPackets = true
                self.processNextWriteItem()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("⚠️ BLE write with response error: \(error.localizedDescription)")
        }
        queueAccessQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.processNextWriteItem()
        }
    }
    
    private func clearWriteQueue(resetSequence: Bool = false) {
        queueAccessQueue.async { [weak self] in
            self?.bleWriteQueue.removeAll()
            self?.isWritingPackets = false
            if resetSequence {
                self?.bleSequenceNumber = 0
                self?.hasLoggedMaxWriteLen = false
            }
        }
    }

    /// Transmits a raw JSON string wrapped into binary protocol frames to the motorcycle TFT display.
    func sendJsonPacket(_ jsonStr: String) {
        writeString(jsonStr)
    }

    /// Requests the motorcycle TFT display to enter screen projection / mirroring mode.
    ///
    /// Transmits two state activation packets:
    /// - `{"msg_id":25, "msg_type":23, "msg_source":2, "status":1}`: Screen mirroring active state.
    /// - `{"msg_id":25, "msg_type":21, "msg_source":2, "status":1}`: CarLife / projection connection status active.
    func startMirroring() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startMirroring() }
            return
        }
        startTcpServers()
        guard connectionState == .connected else {
            log("⏳ BLE is not connected yet. Initiating motorcycle connection before mirroring...")
            reconnectSavedPeripheralIfAvailable()
            startScanning()
            return
        }
        
        log("📤 Start Mirroring requested. Sending Mirror Status packets...")
        
        writeString("{\"msg_id\":25,\"msg_type\":23,\"msg_source\":2,\"status\":1}")
        writeString("{\"msg_id\":25,\"msg_type\":21,\"msg_source\":2,\"status\":1}")
    }
    
    // MARK: - Turn-by-Turn Navigation BLE API
    
    /// Sends the navigation destination name to the motorcycle TFT display header.
    ///
    /// - Message format:
    ///   `{"msg_id":27, "func":"NAVI", "act":1, "dest":"<Sanitized Destination>"}`
    /// - Parameters:
    ///   - destination: Destination place name (sanitized to ASCII to avoid TFT rendering artifacts).
    func sendNavigationDestination(_ destination: String) {
        let sanitized = KoveTextSanitizer.sanitize(destination)
        let json = "{\"msg_id\":27,\"func\":\"NAVI\",\"act\":1,\"dest\":\"\(sanitized)\"}"
        log("🧭 Dashboard Nav Destination: \(sanitized)")
        sendJsonPacket(json)
    }
    
    /// Sends real-time turn-by-turn navigation maneuver instructions to the motorcycle TFT dashboard.
    ///
    /// - Message format:
    ///   ```json
    ///   {
    ///     "msg_id": 27,
    ///     "func": "NAVI",
    ///     "act": 3,
    ///     "icon": <Int>,
    ///     "next_road": "<String>",
    ///     "cur_road": "<String>",
    ///     "retain_rate": <0..100>,
    ///     "cur_retain_distance": "<String>",
    ///     "cur_unittype": <0 for m, 1 for km>,
    ///     "path_retain_distance": "<String>",
    ///     "path_cur_unittype": <0 for m, 1 for km>,
    ///     "cur_retain_time": <Seconds>,
    ///     "remain_time": <Unix Timestamp in Seconds>
    ///   }
    ///   ```
    /// - Parameters:
    ///   - icon: Kove navigation turn icon identifier (e.g. 2: Left, 3: Right, 9: Straight, 21: Arrived).
    ///   - nextRoad: Next turn street/highway name (sanitized ASCII).
    ///   - curRoad: Current road name.
    ///   - retainRate: Route progress percentage (0..100).
    ///   - curRetainDistance: Formatted distance to next maneuver (e.g. "300" or "2.5").
    ///   - curUnitType: Distance unit for current maneuver (0: meters, 1: kilometers).
    ///   - pathRetainDistance: Formatted total remaining trip distance.
    ///   - pathCurUnitType: Distance unit for total remaining distance (0: meters, 1: kilometers).
    ///   - curRetainTime: Estimated remaining travel time in seconds.
    ///   - remainTime: Expected epoch arrival timestamp in seconds.
    func sendNavigationManeuver(
        icon: Int,
        nextRoad: String,
        curRoad: String = "",
        retainRate: Int,
        curRetainDistance: String,
        curUnitType: Int,
        pathRetainDistance: String,
        pathCurUnitType: Int,
        curRetainTime: Int,
        remainTime: Int64
    ) {
        let nextSanitized = KoveTextSanitizer.sanitize(nextRoad)
        let curSanitized = KoveTextSanitizer.sanitize(curRoad)
        let rate = max(0, min(100, retainRate))
        
        let json = "{\"msg_id\":27,\"func\":\"NAVI\",\"act\":3,\"icon\":\(icon),\"next_road\":\"\(nextSanitized)\",\"cur_road\":\"\(curSanitized)\",\"retain_rate\":\(rate),\"cur_retain_distance\":\"\(curRetainDistance)\",\"cur_unittype\":\(curUnitType),\"path_retain_distance\":\"\(pathRetainDistance)\",\"path_cur_unittype\":\(pathCurUnitType),\"cur_retain_time\":\(curRetainTime),\"remain_time\":\(remainTime)}"
        log("🧭 Dashboard Nav Maneuver: icon \(icon), next: '\(nextSanitized)', dist: \(curRetainDistance)\(curUnitType == 0 ? "m" : "km")")
        sendJsonPacket(json)
    }
    
    /// Notifies the motorcycle TFT dashboard that active navigation has ended or been cancelled.
    ///
    /// - Message format: `{"msg_id":15}`
    func sendNavigationEnd() {
        log("🧭 Dashboard Nav End: Sending msg_id 15")
        sendJsonPacket("{\"msg_id\":15}")
    }
    
    /// Stops video screen projection and informs the TFT display to return to native motorcycle dashboard mode.
    ///
    /// Transmits two termination state packets:
    /// - `{"msg_id":25, "msg_type":23, "msg_source":2, "status":0}`: Screen mirroring deactivated.
    /// - `{"msg_id":25, "msg_type":21, "msg_source":2, "status":0}`: CarLife connection deactivated.
    func stopMirroring() {
        hasStartedTFTRide = false
        tftSessionRequested = false
        log("🎬 Stopping screen capture...")
        isStreaming = false
        isBroadcasting = false
        refreshProjectionMode(force: true)
        BackgroundKeepAliveManager.shared.stop()
        
        log("🔌 Stopping TCP Servers in main app...")
        tcpServerManager.stop()
        
        // Notify TFT that mirroring has stopped
        writeString("{\"msg_id\":25,\"msg_type\":23,\"msg_source\":2,\"status\":0}")
        writeString("{\"msg_id\":25,\"msg_type\":21,\"msg_source\":2,\"status\":0}")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("❌ Error reading characteristic value: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value, !data.isEmpty else { return }
        
        // Filter: only process incoming notifications for our notify characteristic (FFE2).
        // Non-FFE2 characteristics (e.g. FFE3) are binary telemetry or debug logs; do not append them to rxBuffer.
        guard characteristic.uuid == notifyCharUUID else {
            let hexStr = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            log("📥 TFT -> BLE (\(characteristic.uuid.uuidString)) Binary: [\(hexStr)] (\(data.count)B)")
            return
        }
        
        // Handle Realtek RTL8762 BLE AT status responses (e.g. AT+Trans_Start)
        if let ascii = String(data: data, encoding: .utf8), ascii.hasPrefix("AT+") {
            log("📥 TFT -> BLE (FFE2) AT Command: \(ascii.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        
        var chunk: String
        if let utf8 = String(data: data, encoding: .utf8) {
            chunk = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            chunk = latin1
        } else {
            let printableBytes = data.filter { ($0 >= 32 && $0 <= 126) || $0 == 10 || $0 == 13 || $0 == 9 }
            chunk = String(bytes: printableBytes, encoding: .ascii) ?? ""
        }
        
        guard !chunk.isEmpty else { return }
        
        // If a standalone packet is missing the leading '{' (e.g. starts with \n\t"msg_id": 10...),
        // repair it by prepending '{' so it parses reliably instead of being discarded as binary.
        if !chunk.contains("{") && rxBuffer.isEmpty {
            if chunk.contains("\"msg_id\"") || chunk.contains("\"item\"") || chunk.contains("\"func\"") {
                chunk = "{" + chunk
            } else {
                let hexStr = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                log("📥 TFT -> BLE (\(characteristic.uuid.uuidString)) Binary: [\(hexStr)] (\(data.count)B)")
                return
            }
        }
        
        rxBuffer.append(chunk)
        
        // Balanced brace JSON object parser (matching Android KoveService / r0.java)
        while true {
            guard let startIndex = rxBuffer.firstIndex(of: "{") else {
                // Buffer has no opening brace, discard any leading noise
                rxBuffer.removeAll()
                break
            }
            
            var depth = 0
            var endIndex: String.Index? = nil
            var currIndex = startIndex
            
            while currIndex < rxBuffer.endIndex {
                let ch = rxBuffer[currIndex]
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = currIndex
                        break
                    }
                }
                currIndex = rxBuffer.index(after: currIndex)
            }
            
            if let end = endIndex {
                let jsonString = String(rxBuffer[startIndex...end])
                rxBuffer.removeSubrange(rxBuffer.startIndex...end)
                handleIncomingJsonText(jsonString)
            } else {
                // Incomplete JSON in buffer - trim leading garbage before startIndex
                if startIndex > rxBuffer.startIndex {
                    rxBuffer.removeSubrange(rxBuffer.startIndex..<startIndex)
                }
                break
            }
        }
    }
    
    /// Decodes and dispatches incoming JSON command packets from the motorcycle TFT display.
    ///
    /// Handles the following protocol message types:
    /// - `msg_id: 10, item: 1`: Motorcycle speed metrics (`current`, `max`, `average` in km/h).
    /// - `msg_id: 10, item: 2`: ODO and Trip distance counters (values in hectometers / tenths of km).
    /// - `msg_id: 10, item: 4`: Periodic keepalive ping from TFT (requires response `{"msg_id":11, "time":..., "tag":tag}`).
    /// - `msg_id: 10, item: 7`: Current transmission sequence index from TFT (`cur_package_index`).
    /// - `msg_id: 10, item: 9`: Packet loss diagnostic counter (`packet_loss_index`).
    /// - `msg_id: 27, act: "send_pairinfo"` / `"send_pairresult"`: BLE pairing status confirmation.
    /// - Handlebar & media buttons (forwarded to `HandlebarKeyManager`).
    func handleIncomingJsonText(_ text: String) {
        log("📥 TFT -> BLE: \(text)")
        
        // Process handlebar controls over BLE
        HandlebarKeyManager.shared.processJsonText(text)
        
        guard let jsonData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        receiveMotorcycleDistances(json)
        
        // Respond to TFT messages: msg_id 10
        if let msgId = json["msg_id"] as? Int, msgId == 10 {
            let item = json["item"] as? Int ?? 0
            switch item {
            case 1:
                // Speed & trip metrics: "current", "max", "average"
                let current = json["current"] as? Int ?? 0
                let maxSpeed = json["max"] as? Int ?? 0
                let avgSpeed = json["average"] as? Int ?? 0
                log("📊 Motorcycle Speed Stats: Current=\(current) km/h, Max=\(maxSpeed) km/h, Avg=\(avgSpeed) km/h")
                
            case 4:
                // Periodic ping from TFT: msg_id 10, item 4, tag: X
                // App replies with: {"msg_id":11,"time":"yyyy-MM-dd HH:mm:ss","tag":tag}
                let tag = json["tag"] as? Int ?? 0
                let timeStr = getCurrentTimeString()
                let reply = "{\"msg_id\":11,\"time\":\"\(timeStr)\",\"tag\":\(tag)}"
                log("📥 TFT Ping received (msg_id: 10, item: 4, tag: \(tag)) -> Replying with msg_id: 11")
                writeString(reply)
                DispatchQueue.main.async { [weak self] in
                    self?.lastClockSyncDate = Date()
                }
                
            case 6:
                // TFT Version response (in response to msg_id: 13)
                // Thinkerride protocol: sends sendCurrentDateTime(-1) upon receiving version info
                let version = json["version"] as? String ?? ""
                let sysVersion = json["sysversion"] as? String ?? ""
                let mcuVersion = json["mcuversion"] as? String ?? ""
                log("ℹ️ TFT Firmware Version: \(version), MCU: \(mcuVersion), Sys: \(sysVersion)")
                log("🕒 TFT Version acknowledged -> Syncing clock time to screen...")
                syncTime()
                
            case 7:
                // TFT Current Sequence status: {"msg_id":10,"item":7,"cur_package_index":X}
                if let curPkgIndex = json["cur_package_index"] as? Int {
                    log("📥 TFT sequence status: cur_package_index = \(curPkgIndex)")
                }
                
            case 9:
                // TFT Packet Loss status: {"msg_id":10,"item":9,"packet_loss_index":X}
                let lossIndex = json["packet_loss_index"] as? Int ?? 0
                if lossIndex > 0 {
                    log("⚠️ TFT reported packet loss index: \(lossIndex)")
                } else {
                    log("✅ TFT reported packet_loss_index: 0 (No packet loss)")
                }
                
            default:
                break
            }
        }
        
        // Parse for pairing confirmation (send_pairresult or send_pairinfo)
        var pairingConfirmed = false
        if let msgId = json["msg_id"] as? Int, msgId == 27,
           let act = json["act"] as? String {
            if act == "send_pairinfo" || (act == "send_pairresult" && (json["result"] as? Int == 1)) {
                pairingConfirmed = true
            }
        } else if text.contains("send_pairinfo") || (text.contains("send_pairresult") && (text.contains("\"result\":1") || text.contains("\"result\": 1"))) {
            pairingConfirmed = true
        }
        
        if pairingConfirmed {
            log("✅ BLE pairing confirmed by TFT (\(json["act"] as? String ?? "pairinfo"))! Syncing clock & requesting mileage.")
            syncTime()
            if odoDistanceKm == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, self.connectionState == .connected, self.odoDistanceKm == nil else { return }
                    self.requestMileage()
                }
            }
        }
    }

    private func receiveMotorcycleDistances(_ json: [String: Any]) {
        guard let packet = MotorcycleDistancePacket.decode(json),
              let peripheralID = targetPeripheral?.identifier, connectionState == .connected else { return }
        let receivedAt = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionState == .connected,
                  self.targetPeripheral?.identifier == peripheralID else { return }
            if let trip = packet.tripKilometers { self.tripDistanceKm = trip }
            guard let kilometers = packet.odometerKilometers else { return }
            let reading = MotorcycleOdometer(kilometers: kilometers, peripheralID: peripheralID, receivedAt: receivedAt)
            self.odoDistanceKm = kilometers
            self.motorcycleOdometer = reading
            self.mileageSyncMessage = nil
        }
    }
    
    // MARK: - Handshake and Heartbeat Protocol
    
    /// Requests the current total Odometer (ODO) and Trip distance metrics from the motorcycle TFT.
    ///
    /// Message format: `{"msg_id":10, "item":2}`
    func requestMileage() {
        log("📤 Requesting ODO and Trip distances from motorcycle...")
        writeString("{\"msg_id\":10,\"item\":2}")
    }
    
    /// Sends the initial initialization sequence following BLE connection and characteristic subscription.
    ///
    /// Sequence steps (matching ThinkerRide / Kove protocol):
    /// 1. `{"msg_id":27, "func":"PAIR", "act":"get_pairinfo"}`: Request pairing credentials and verification.
    /// 2. `{"msg_id":13}`: Query handshake status.
    /// 3. `{"msg_id":25, "msg_type":18, "msg_source":2, "language":2}`: Set TFT language preference (2 = English).
    /// 4. `{"msg_id":11, "time":"...", "tag":-1}`: Synchronize motorcycle dashboard clock to phone system time.
    /// 5. `{"msg_id":10, "item":2}`: Query initial ODO and trip mileage.
    /// 6. `{"msg_id":25, "msg_type":23, "msg_source":2, "status":0}`: Ensure TFT initializes in native Dashboard mode (mirroring idle).
    /// 7. `{"msg_id":25, "msg_type":21, "msg_source":2, "status":0}`: Set projection connection mode idle.
    private func sendInitHandshake() {
        log("📤 Sending initial BLE handshake sequence...")
        let projectionStatus = tftSessionRequested && (isStreaming || isTFTControlConnected) ? 1 : 0
        
        // Matches ThinkerRide / Android KoveGo BLE handshake: pairinfo, msg_id 13, language, time sync (tag: -1), ODO request,
        // and explicit status: 0 to ensure TFT starts in Dashboard / Simple Navigation mode (not Screen Mirroring).
        let packets = [
            "{\"msg_id\":27,\"func\":\"PAIR\",\"act\":\"get_pairinfo\"}",
            "{\"msg_id\":13}",
            "{\"msg_id\":25,\"msg_type\":18,\"msg_source\":2,\"language\":2}",
            "{\"msg_id\":11,\"time\":\"\(getCurrentTimeString())\",\"tag\":-1}",
            "{\"msg_id\":10,\"item\":2}",
            "{\"msg_id\":25,\"msg_type\":23,\"msg_source\":2,\"status\":\(projectionStatus)}",
            "{\"msg_id\":25,\"msg_type\":21,\"msg_source\":2,\"status\":\(projectionStatus)}"
        ]
        
        DispatchQueue.main.async { [weak self] in
            self?.lastClockSyncDate = Date()
        }
        
        // Android version sends packets in sequence with a 150ms delay
        for packetStr in packets {
            writeString(packetStr)
        }
        if tftSessionRequested && automaticConnectionEnabled {
            startMirroring()
            reconnectWiFiIfNeeded()
        }
        
        // Defer telemetry & navigation sync slightly so handshake packets are transmitted first without congestion
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.connectionState == .connected else { return }
            TelemetrySyncManager.shared.startSync(bleController: self)
            NavigationSyncManager.shared.startSync(bleController: self)
        }
    }
    
    private func startMileageTimer() {
        mileageTimer?.invalidate()
        log("⏱️ Starting periodic ODO & Trip sync timer (every 2 minutes)")
        
        // Initial request after 4.0s settling time
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self, self.connectionState == .connected else { return }
            self.requestMileage()
        }
        
        // Repeating every 120 seconds (2 minutes)
        mileageTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: true) { [weak self] _ in
            guard let self = self, self.connectionState == .connected else { return }
            self.requestMileage()
        }
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        log("💓 Starting BLE Heartbeat timer (5.0s interval)")
        
        sendHeartbeatPacket()
        
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sendHeartbeatPacket()
        }
    }
    
    /// Sends a keepalive heartbeat packet to maintain active communication with the TFT MCU.
    ///
    /// Message format: `{"msg_id":25, "msg_type":24, "msg_source":2, "status":1}`
    private func sendHeartbeatPacket() {
        writeString("{\"msg_id\":25,\"msg_type\":24,\"msg_source\":2,\"status\":1}")
    }
    
    /// Synchronizes the motorcycle TFT dashboard clock to the phone's current local time.
    ///
    /// Transmits a time synchronization packet adhering to the Thinkerride / Kove protocol:
    /// `{"msg_id": 11, "time": "yyyy-MM-dd HH:mm:ss", "tag": -1}`
    ///
    /// - Parameter tag: Protocol tag identifier (-1 for active clock setting, >= 0 for keepalive ping response).
    func syncTime(tag: Int = -1) {
        let timeStr = getCurrentTimeString()
        let json = "{\"msg_id\":11,\"time\":\"\(timeStr)\",\"tag\":\(tag)}"
        log("🕒 Syncing motorcycle clock time to TFT: \(timeStr) (tag: \(tag))")
        writeString(json)
        DispatchQueue.main.async { [weak self] in
            self?.lastClockSyncDate = Date()
        }
    }
    
    /// Formats the current or given Date into the strict 24-hour Gregorian format required by the TFT MCU.
    /// Uses POSIX locale and Gregorian calendar to avoid 12-hour AM/PM or non-Gregorian year bugs.
    func getCurrentTimeString(for date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }
}

// MARK: - Preview Helpers
extension BleController {
    static func preview(
        state: BleState = .disconnected,
        deviceName: String? = nil,
        isStreaming: Bool = false,
        isBroadcasting: Bool = false,
        odoDistanceKm: Double? = nil,
        tripDistanceKm: Double? = nil,
        lastClockSyncDate: Date? = nil,
        logs: [String] = []
    ) -> BleController {
        let controller = BleController(isPreview: true)
        controller.connectionState = state
        controller.connectedDeviceName = deviceName
        controller.isStreaming = isStreaming
        controller.isBroadcasting = isBroadcasting
        controller.odoDistanceKm = odoDistanceKm
        controller.tripDistanceKm = tripDistanceKm
        controller.lastClockSyncDate = lastClockSyncDate
        controller.logMessages = logs
        return controller
    }
}
