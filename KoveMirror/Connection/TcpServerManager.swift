import Foundation
import Network
import Darwin

// A value passed between the UI and the serial network queue.
nonisolated enum ProjectionVideoSource: Equatable, Sendable { case screen, navigation, broadcast, paused }

class TcpServerManager {
    private var controlListener: NWListener?
    private var videoListener: NWListener?
    private var heartbeatListener: NWListener?
    private var localVideoListener: NWListener?
    
    private var controlConnection: NWConnection?
    private var videoConnection: NWConnection?
    private var videoReadySince: TimeInterval?
    private var heartbeatConnection: NWConnection?
    private var localVideoConnection: NWConnection?
    // Read and written only on networkQueue. Avoid mixing two H.264 bitstreams.
    private var selectedVideoSource: ProjectionVideoSource = .paused
    private var broadcastResynchronizer = AnnexBResynchronizer()

    func selectVideoSource(_ source: ProjectionVideoSource) {
        networkQueue.async { [weak self] in
            if self?.selectedVideoSource != source { self?.broadcastResynchronizer.reset() }
            self?.selectedVideoSource = source
        }
    }
    
    private var heartbeatTimer: DispatchSourceTimer?
    private var videoHeartbeatTimer: DispatchSourceTimer?
    
    private let networkQueue = DispatchQueue(label: "com.kove.mirror.network", qos: .userInteractive)
    private var handshakeCompleted = false
    private var videoFrameCount = 0
    // Outstanding NWConnection writes, accessed only from networkQueue.
    private var pendingVideoBytes = 0
    private var pendingVideoWrites = 0
    private var videoWidth = 600
    private var videoHeight = 1024
    
    var onVideoBytesSent: (@Sendable (Int, TimeInterval?) -> Void)?
    var onVideoError: ((String) -> Void)?
    var onVideoConnectionChanged: ((Bool) -> Void)?
    var onControlConnectionChanged: ((Bool) -> Void)?
    var onLocalConnectionChanged: ((Bool) -> Void)?
    var onControlPacketReceived: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onControlHandshakeCompleted: (() -> Void)?
    private var onVideoConnectCallback: (() -> Void)?
    
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenConfigChanged),
            name: KoveScreenPreset.configChangedNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleScreenConfigChanged() {
        networkQueue.async { [weak self] in self?.sendConfigToExtension() }
    }
    
    func startServers(width: Int, height: Int, onVideoConnect: @escaping () -> Void) {
        networkQueue.async { [weak self] in
            self?.startServersOnNetworkQueue(width: width, height: height, onVideoConnect: onVideoConnect)
        }
    }

    private func startServersOnNetworkQueue(width: Int, height: Int, onVideoConnect: @escaping () -> Void) {
        onVideoConnectCallback = onVideoConnect
        videoWidth = width
        videoHeight = height
        // BLE can reconnect while the Wi-Fi channel is still healthy. Re-arming
        // listeners must never cancel those active sockets.
        
        // Trigger local network access permission prompt on iOS
        triggerLocalNetworkPrompt()
        
        let ip = getWifiIpAddress() ?? "unknown"
        print("📡 Active Wi-Fi IP Address (en0): \(ip)")
        
        // Setup server listeners if they are not already active
        if controlListener == nil {
            setupControlServer()
        }
        if heartbeatListener == nil {
            setupHeartbeatServer()
        }
        if videoListener == nil {
            setupVideoServer(width: width, height: height)
        }
        if localVideoListener == nil {
            setupLocalVideoServer()
        }
        
        print("TCP Servers initialized in Main App. Video on 15456, Heartbeat on 15457, Control on 17818.")
    }

    /// A failed NWListener cannot accept connections again. Release only that
    /// listener so the next retry can recreate it without closing live sockets.
    private func observeListener(_ listener: NWListener,
                                 at keyPath: ReferenceWritableKeyPath<TcpServerManager, NWListener?>,
                                 port: UInt16) {
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self[keyPath: keyPath] === listener else { return }
            switch state {
            case .failed(let error):
                self[keyPath: keyPath] = nil
                listener.cancel()
                let message = "Écoute TFT " + String(port) + " interrompue : " + error.localizedDescription
                self.onLog?(message)
                self.onVideoError?(message)
            case .cancelled:
                self[keyPath: keyPath] = nil
            case .waiting(let error):
                self.onLog?("Écoute TFT " + String(port) + " en attente : " + error.localizedDescription)
            default:
                break
            }
        }
    }
    
    // MARK: - Port 17818 (Control Server)
    
    private func setupControlServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi // Force Wi-Fi interface
            
            controlListener = try NWListener(using: parameters, on: 17818)
            if let controlListener { observeListener(controlListener, at: \.controlListener, port: 17818) }
            controlListener?.newConnectionHandler = { [weak self] connection in
                self?.handleControlConnection(connection)
            }
            controlListener?.start(queue: networkQueue)
        } catch {
            print("❌ Control Listener failed to start: \(error.localizedDescription)")
        }
    }
    
    private func handleControlConnection(_ connection: NWConnection) {
        controlConnection?.cancel()
        controlConnection = connection
        handshakeCompleted = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.controlConnection === connection else { return }
            switch state {
            case .ready:
                print("🔌 Control connection ready.")
                self.onControlConnectionChanged?(true)
                self.sendControlInitSequence(connection)
                self.readControlData(connection)
            case .failed(let error):
                print("❌ Control connection failed: \(error.localizedDescription)")
                self.onLog?("Contrôle TFT perdu : " + error.localizedDescription)
                self.controlConnection = nil
                self.onControlConnectionChanged?(false)
            case .cancelled:
                print("🔌 Control connection cancelled.")
                self.controlConnection = nil
                self.onControlConnectionChanged?(false)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func sendControlInitSequence(_ connection: NWConnection) {
        print("📤 Sending Control 17818 Handshake Sequence...")
        // 1. Binary Firmware Version Request: [0x01, 0x01, 0x00, 0x00, 0x00, 0x00]
        let versionBytes = Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00])
        connection.send(content: versionBytes, completion: .contentProcessed({ _ in }))
        
        // 2. Binary MAC Request: [0x01, 0x11, 0x00, 0x00, 0x00, 0x00]
        let macBytes = Data([0x01, 0x11, 0x00, 0x00, 0x00, 0x00])
        connection.send(content: macBytes, completion: .contentProcessed({ _ in }))
        
        // 3. Framed JSON Queries
        sendFramedJson(connection, "{\"msg_id\":27,\"func\":\"INSIDENAVI\",\"query\":1}")
        sendFramedJson(connection, "{\"msg_id\":27,\"func\":\"INSIDENAVI\",\"query\":2}")
        sendFramedJson(connection, "{\"msg_id\":27,\"func\":\"CAR_INFO\",\"act\":\"get_car_info\"}")
        sendFramedJson(connection, "{\"msg_id\":27,\"func\":\"TUC\",\"act\":\"GET\"}")
    }
    
    private func sendFramedJson(_ connection: NWConnection, _ jsonStr: String) {
        guard let jsonBytes = jsonStr.data(using: .utf8) else { return }
        let len = Int32(jsonBytes.count)
        
        print("📤 Sending framed JSON: \(jsonStr)")
        
        var frame = Data()
        frame.append(0xEE)
        frame.append(0xFD)
        
        // Write 4-byte big endian integer length
        withUnsafeBytes(of: len.bigEndian) { frame.append(contentsOf: $0) }
        
        frame.append(jsonBytes)
        frame.append(0xFF)
        
        connection.send(content: frame, completion: .contentProcessed({ error in
            if let error = error {
                print("❌ Error sending framed JSON: \(error.localizedDescription)")
            } else {
                print("✅ Framed JSON sent successfully: \(jsonStr)")
            }
        }))
    }
    
    private func extractJsonText(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), text.contains("{") {
            return text
        }
        let printableBytes = data.filter { ($0 >= 32 && $0 <= 126) || $0 == 10 || $0 == 13 || $0 == 9 }
        return String(bytes: printableBytes, encoding: .ascii) ?? ""
    }
    
    private func readControlData(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.controlConnection === connection else { return }
            if let error = error {
                print("❌ Error receiving control data: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                print("📥 Received control packet (\(data.count) bytes)")
                let text = self.extractJsonText(from: data)
                if !text.isEmpty && text.contains("{") {
                    print("📥 Control packet content: \(text)")
                    self.onLog?("📥 TFT Control (Port 17818): \(text)")
                    self.onControlPacketReceived?(text)
                } else {
                    let hexStr = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("📥 Control packet content (hex): [\(hexStr)] (\(data.count)B)")
                    self.onLog?("📥 TFT Control (Port 17818 Hex): [\(hexStr)] (\(data.count)B)")
                    self.onControlPacketReceived?(text)
                }
                
                // Echo Control Port Heartbeat packets (02 01 00 00 00 00) back to TFT
                if data.count == 6 && data[0] == 0x02 && data[1] == 0x01 && data[2] == 0x00 {
                    connection.send(content: data, completion: .contentProcessed({ error in
                        if error == nil {
                            print("💓 Control Heartbeat Echoed back to TFT (17818).")
                        }
                    }))
                }
                
                if !self.handshakeCompleted {
                    self.handshakeCompleted = true
                    // Small delay to let initial data settle, matching Android's Thread.sleep(100)
                    self.networkQueue.asyncAfter(deadline: .now() + 0.1) {
                        guard self.controlConnection === connection else { return }
                        self.sendControlHandshake(connection)
                    }
                }
            }
            
            if !isComplete && error == nil {
                self.readControlData(connection)
            } else if isComplete {
                connection.cancel()
            }
        }
    }
    
    private func sendControlHandshake(_ connection: NWConnection) {
        print("📤 Sending binary handshake packets...")
        
        let emailBody = "yahoo@yahoo.com".data(using: .utf8)!.paddingTo256Bytes()
        
        var handshakeData = Data()
        handshakeData.append(Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00])) // Cmd 1 (6 bytes)
        handshakeData.append(Data([0x01, 0x17, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02])) // Cmd 23 (10 bytes)
        handshakeData.append(Data([0x01, 0x12, 0x00, 0x00, 0x01, 0x00]) + emailBody) // Cmd 18 (262 bytes)
        handshakeData.append(Data([0x01, 0x0E, 0x00, 0x00, 0x00, 0x00])) // Cmd 14 (6 bytes)
        handshakeData.append(Data([0x01, 0x11, 0x00, 0x00, 0x00, 0x00])) // Cmd 17 (6 bytes)
        
        connection.send(content: handshakeData, completion: .contentProcessed({ error in
            if let error = error {
                print("❌ Error sending binary handshake: \(error.localizedDescription)")
            }
        }))
        
        // Followed by INSIDENAVI query packets
        sendFramedJson(connection, "{\"msg_id\":27,\"func\":\"INSIDENAVI\",\"query\":2}")
        sendFramedJson(connection, "{\"msg_id\":27,\"func\":\"INSIDENAVI\",\"query\":1}")
        print("✅ Control handshake completed.")
        onControlHandshakeCompleted?()
    }

    // MARK: - Port 15457 (Dedicated Heartbeat Server)
    
    private func setupHeartbeatServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            
            heartbeatListener = try NWListener(using: parameters, on: 15457)
            if let heartbeatListener { observeListener(heartbeatListener, at: \.heartbeatListener, port: 15457) }
            heartbeatListener?.newConnectionHandler = { [weak self] connection in
                self?.handleHeartbeatConnection(connection)
            }
            heartbeatListener?.start(queue: networkQueue)
        } catch {
            print("❌ Heartbeat Listener failed: \(error.localizedDescription)")
        }
    }
    
    private func handleHeartbeatConnection(_ connection: NWConnection) {
        heartbeatConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if state == .ready {
                print("🔌 Dedicated Heartbeat connection ready. Starting 200ms pulses...")
                self.startDedicatedHeartbeat(connection)
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func startDedicatedHeartbeat(_ connection: NWConnection) {
        heartbeatTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        
        let packet = Data([0x02, 0x01, 0x00, 0x00, 0x00, 0x00]) // 6-byte keep alive packet
        
        timer.setEventHandler { [weak connection] in
            guard let connection = connection else { return }
            connection.send(content: packet, completion: .contentProcessed({ error in
                if error != nil {
                    print("⚠️ Failed to send heartbeat pulse, connection might be closed.")
                }
            }))
        }
        
        heartbeatTimer = timer
        timer.resume()
    }
    
    // MARK: - Port 15456 (Video / Projection Server)
    
    private func setupVideoServer(width: Int, height: Int) {
        do {
            let parameters = NWParameters.tcp
            // Disable Nagle on the TFT video socket to avoid short-packet delay.
            (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            parameters.requiredInterfaceType = .wifi

            videoListener = try NWListener(using: parameters, on: 15456)
            if let videoListener { observeListener(videoListener, at: \.videoListener, port: 15456) }
            videoListener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.handleVideoConnection(connection, width: self.videoWidth, height: self.videoHeight)
            }
            videoListener?.start(queue: networkQueue)
            
        } catch {
            print("❌ Video Listener failed: \(error.localizedDescription)")
        }
    }
    
    private func handleVideoConnection(_ connection: NWConnection, width: Int, height: Int) {
        videoConnection?.cancel()
        videoHeartbeatTimer?.cancel()
        videoHeartbeatTimer = nil
        videoReadySince = nil
        selectedVideoSource = .paused
        broadcastResynchronizer.reset()
        pendingVideoBytes = 0
        pendingVideoWrites = 0
        videoConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.videoConnection === connection else { return }
            if state == .ready {
                print("🔌 Video connection established.")
                self.sendVideoSizeHeader(connection, width: width, height: height)
            } else if case .failed(let error) = state {
                self.videoConnection = nil
                self.videoReadySince = nil
                self.videoHeartbeatTimer?.cancel()
                self.videoHeartbeatTimer = nil
                self.onVideoError?("Connexion vidéo perdue : " + error.localizedDescription)
                self.onVideoConnectionChanged?(false)
            } else if state == .cancelled {
                self.videoConnection = nil
                self.videoReadySince = nil
                self.videoHeartbeatTimer?.cancel()
                self.videoHeartbeatTimer = nil
                self.onVideoConnectionChanged?(false)
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func sendVideoSizeHeader(_ connection: NWConnection, width: Int, height: Int) {
        var header = Data(repeating: 0, count: 69)
        
        // Padded OS name. TFT dashboard expects "android" to set up correct scaling buffer.
        let nameStr = "android"
        if let nameData = nameStr.data(using: .utf8) {
            header.replaceSubrange(1..<1+nameData.count, with: nameData)
        }
        
        header[65] = UInt8((width >> 8) & 0xFF)
        header[66] = UInt8(width & 0xFF)
        header[67] = UInt8((height >> 8) & 0xFF)
        header[68] = UInt8(height & 0xFF)
        
        let hexStr = header.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("📤 Sending VideoSize header (Width: \(width), Height: \(height)). Hex: \(hexStr)")
        
        connection.send(content: header, completion: .contentProcessed({ [weak self, weak connection] error in
            guard let self, let connection, self.videoConnection === connection else { return }
            if let error {
                self.onVideoError?("En-tête vidéo TFT : " + error.localizedDescription)
                connection.cancel()
                return
            }
            self.videoReadySince = ProcessInfo.processInfo.systemUptime
            self.startVideoHeartbeat(connection)
            self.onVideoConnectCallback?()
        }))
    }
    
    private func startVideoHeartbeat(_ connection: NWConnection) {
        videoHeartbeatTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        
        let packet = Data([0x02, 0x01, 0x00, 0x00, 0x00, 0x00])
        
        timer.setEventHandler { [weak connection] in
            guard let connection = connection else { return }
            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        }
        
        videoHeartbeatTimer = timer
        timer.resume()
    }
    
    /// Called by the snapshot producer (never from networkQueue). Block for
    /// just the queue's tiny state read; don't queue obsolete frames for seconds.
    func canAcceptNewVideoFrame(maxPendingWrites: Int = 2) -> Bool {
        networkQueue.sync {
            // Small delta frames can pile up long before the byte limit is hit.
            videoReadySince != nil && selectedVideoSource == .screen && pendingVideoWrites < maxPendingWrites &&
                pendingVideoBytes < TFTFrameRatePolicy.maxPendingVideoBytes
        }
    }

    func streamVideoFrame(data: Data, source: ProjectionVideoSource = .screen, capturedAt: TimeInterval? = nil) {
        networkQueue.async { [weak self] in
            self?.sendVideoFrameOnNetworkQueue(data: data, source: source, capturedAt: capturedAt)
        }
    }

    private func sendVideoFrameOnNetworkQueue(data: Data, source: ProjectionVideoSource, capturedAt: TimeInterval? = nil) {
        guard source == selectedVideoSource, let connection = videoConnection, let readySince = videoReadySince,
              capturedAt.map({ $0 >= readySince }) ?? true else { return }
        videoFrameCount += 1
        if videoFrameCount % 100 == 0 {
            print("📺 Sent 100 video frames. Current NAL unit size: \(data.count) bytes. Total frames sent: \(videoFrameCount)")
        }
        
        pendingVideoBytes += data.count
        pendingVideoWrites += 1
        connection.send(content: data, completion: .contentProcessed({ [weak self, weak connection] error in
            guard let self, let connection, self.videoConnection === connection else { return }
            self.pendingVideoBytes = max(0, self.pendingVideoBytes - data.count)
            self.pendingVideoWrites = max(0, self.pendingVideoWrites - 1)
            if let error {
                self.onVideoError?("Envoi vidéo : " + error.localizedDescription)
                // Reconnect at a keyframe after a failed write in the H.264 stream.
                connection.cancel()
            } else {
                self.onVideoBytesSent?(data.count, capturedAt)
            }
        }))
    }
    
    // MARK: - Local Video Forwarder (Port 15455)
    
    private func setupLocalVideoServer() {
        if localVideoListener != nil { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback // Loopback only for localhost security
            
            localVideoListener = try NWListener(using: parameters, on: 15455)
            if let localVideoListener { observeListener(localVideoListener, at: \.localVideoListener, port: 15455) }
            localVideoListener?.newConnectionHandler = { [weak self] connection in
                self?.handleLocalVideoConnection(connection)
            }
            localVideoListener?.start(queue: networkQueue)
            print("🔌 Local video receiver server opened on 127.0.0.1:15455")
        } catch {
            print("❌ Local Video Listener failed: \(error.localizedDescription)")
        }
    }
    
    private func handleLocalVideoConnection(_ connection: NWConnection) {
        let previous = localVideoConnection
        localVideoConnection = connection
        // A restarted broadcast has its own SPS/PPS and IDR. Do not reuse
        // decoder state, or let a previous connection cancel the new one.
        broadcastResynchronizer.reset()
        previous?.cancel()
        onLocalConnectionChanged?(false)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.localVideoConnection === connection else { return }
            switch state {
            case .ready:
                print("🔌 Local video client connected.")
                self.onLocalConnectionChanged?(true)
                self.sendConfigToExtension()
                self.readLocalVideoData(connection)
            case .failed, .cancelled:
                print("🔌 Local video client disconnected.")
                self.localVideoConnection = nil
                self.broadcastResynchronizer.reset()
                self.onLocalConnectionChanged?(false)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func readLocalVideoData(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.localVideoConnection === connection else { return }
            if let error = error {
                print("❌ Error reading local video data: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                // Never resume a new H.264 stream in the middle of a NAL.
                if self.selectedVideoSource == .broadcast,
                   let synchronizedData = self.broadcastResynchronizer.append(data) {
                    self.sendVideoFrameOnNetworkQueue(data: synchronizedData, source: .broadcast)
                }
            }
            
            if !isComplete && error == nil {
                self.readLocalVideoData(connection)
            } else if isComplete {
                connection.cancel()
            }
        }
    }
    
    func sendConfigToExtension() {
        guard let connection = localVideoConnection else { return }
        let top = KoveScreenPreset.topPadding
        let bottom = KoveScreenPreset.bottomPadding
        let keepAspect = KoveScreenPreset.keepAspectRatio
        let preset = KoveScreenPreset.current
        let configDict: [String: Any] = [
            "type": "config",
            "top": top,
            "bottom": bottom,
            "keepAspect": keepAspect,
            "framing": KoveScreenPreset.broadcastFraming.serialized ?? "invalid",
            "width": preset.width,
            "height": preset.height
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: configDict) else { return }
        var packet = data
        packet.append(0x0A) // Newline delimiter
        connection.send(content: packet, completion: .contentProcessed({ error in
            if let error = error {
                print("⚠️ Failed sending config to extension: \(error.localizedDescription)")
            } else {
                print("📡 Sent screen config to extension: \(preset.width)x\(preset.height), top=\(top), bottom=\(bottom)")
            }
        }))
    }
    
    // MARK: - Lifecycle Management
    
    func stop() {
        networkQueue.async { [weak self] in self?.stopActiveConnections() }
    }
    
    func stopActiveConnections() {
        print("🔌 Stopping active TCP connections...")
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        
        videoHeartbeatTimer?.cancel()
        videoHeartbeatTimer = nil
        
        controlConnection?.cancel()
        controlConnection = nil
        
        videoConnection?.cancel()
        videoConnection = nil
        videoReadySince = nil
        
        heartbeatConnection?.cancel()
        heartbeatConnection = nil
        
        localVideoConnection?.cancel()
        localVideoConnection = nil
        
        handshakeCompleted = false
        onControlConnectionChanged?(false)
        onVideoConnectionChanged?(false)
        onLocalConnectionChanged?(false)
    }
    
    func stopAll() {
        print("🔌 Shutting down all TCP listeners and connections...")
        stopActiveConnections()
        
        controlListener?.cancel()
        controlListener = nil
        
        videoListener?.cancel()
        videoListener = nil
        
        heartbeatListener?.cancel()
        heartbeatListener = nil
        
        localVideoListener?.cancel()
        localVideoListener = nil
    }
    
    private func triggerLocalNetworkPrompt() {
        // Send a dummy UDP packet to a multicast address to trigger the iOS Local Network access permission prompt.
        let connection = NWConnection(
            host: "255.255.255.255",
            port: 8888,
            using: .udp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let data = "ping".data(using: .utf8)
                connection.send(content: data, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
        connection.start(queue: .global())
        print("📡 Sent local network UDP broadcast to trigger permission prompt.")
    }
    
    private func getWifiIpAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while ptr != nil {
            if let interface = ptr {
                let name = String(cString: interface.pointee.ifa_name)
                if name == "en0" {
                    let addr = interface.pointee.ifa_addr.pointee
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        var addrCopy = addr
                        if getnameinfo(&addrCopy, socklen_t(addrCopy.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                            address = String(cString: hostname)
                            break
                        }
                    }
                }
                ptr = interface.pointee.ifa_next
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}

// MARK: - Helper Extension for Handshake Padding

extension Data {
    func paddingTo256Bytes() -> Data {
        var padded = self
        if padded.count < 256 {
            padded.append(Data(repeating: 0, count: 256 - padded.count))
        } else if padded.count > 256 {
            padded = padded.subdata(in: 0..<256)
        }
        return padded
    }
}
