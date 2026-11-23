import Foundation
import VideoToolbox

nonisolated protocol H264EncoderDelegate: AnyObject {
    nonisolated func encoderDidOutputNALUnit(data: Data)
    nonisolated func encoderDidOutputNALUnit(data: Data, pts: CMTime)
}

extension H264EncoderDelegate {
    nonisolated func encoderDidOutputNALUnit(data: Data, pts: CMTime) {
        encoderDidOutputNALUnit(data: data)
    }
}

nonisolated final class H264Encoder {
    weak var delegate: H264EncoderDelegate?
    var onError: (@Sendable (OSStatus) -> Void)?
    private var session: VTCompressionSession?
    private var frameCount = 0
    private var keyframeInterval = 15
    deinit { stop() }
    
    @discardableResult
    func start(width: Int32, height: Int32, fps: Int32) -> Bool {
        stop()
        frameCount = 0
        keyframeInterval = max(1, Int(fps))
        // Calculate dynamic bitrate similar to Android version
        let bitrate = width * height * 2 // ~1.23 Mbps at 600x1024, less Wi-Fi queueing
        print("🎬 Starting H.264 Encoder (\(width)x\(height) @ \(fps) FPS, Bitrate: \(bitrate / 1000) Kbps)")
        
        let sourceImageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA as CFNumber,
            kCVPixelBufferWidthKey: width as CFNumber,
            kCVPixelBufferHeightKey: height as CFNumber
        ]
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceImageBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("❌ VTCompressionSessionCreate failed: \(status)")
            onError?(status)
            return false
        }
        
        // Configure Real-Time encoding properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber) // Force I-frame every 1 second
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        
        // Disable B-frames (Frame Reordering) for low-latency real-time rendering compat
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        // Set bit rate limits
        let limit = [bitrate * 2 / 8, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
        
        // Configure profile: AVC High Profile, Level 4.1
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_4_1)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        
        // Prepare to encode
        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepStatus != noErr {
            print("❌ VTCompressionSessionPrepareToEncodeFrames failed: \(prepStatus)")
            onError?(prepStatus)
            stop()
            return false
        } else {
            print("✅ H.264 VideoToolbox Session initialized successfully.")
        }
        return true
    }
    
    @discardableResult
    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false,
                flushImmediately: Bool = false) -> Bool {
        guard let session = session else { return false }
        
        frameCount += 1
        var frameProperties: CFDictionary? = nil
        if forceKeyframe || frameCount == 1 || frameCount % keyframeInterval == 0 {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        
        var status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        // A GPS-driven frame may be the last one for a while. Emit it on the
        // encoder queue now, without waiting for a subsequent location sample.
        if status == noErr && flushImmediately {
            status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        }
        if status != noErr {
            print("⚠️ H.264 frame error: \(status)")
            onError?(status)
        }
        return status == noErr
    }
    
    func stop() {
        if let session = session {
            print("🎬 Inactivating H.264 Encoder...")
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
            print("✅ Encoder session terminated.")
        }
    }
}

// MARK: - VideoToolbox Compression Callback

private nonisolated func outputCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrameRefcon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    guard status == noErr, let sampleBuffer = sampleBuffer else {
        print("⚠️ H.264 compression callback error or empty buffer: \(status)")
        if status != noErr { encoder.onError?(status) }
        return
    }
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyFrame = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    var parameterCount = 0
    var headerLength: Int32 = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
        parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount,
        nalUnitHeaderLengthOut: &headerLength
    ) == noErr else { return }

    var frame = Data()
    if isKeyFrame {
        for index in 0..<parameterCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 else { return }
            frame.append(contentsOf: [0, 0, 0, 1])
            frame.append(pointer, count: size)
        }
    }

    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let count = CMBlockBufferGetDataLength(block)
    guard count > 0 else { return }
    var contiguous = 0
    var pointer: UnsafeMutablePointer<Int8>?
    let pointerStatus = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous,
                                             totalLengthOut: nil, dataPointerOut: &pointer)
    let complete: Bool
    if pointerStatus == noErr, contiguous == count, let pointer {
        let start = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        complete = AnnexBResynchronizer.appendAVCC(UnsafeBufferPointer(start: start, count: count),
                                                   lengthBytes: Int(headerLength), to: &frame)
    } else {
        // A Core Media block may have several non-adjacent pieces.
        var copy = Data(count: count)
        let copied = copy.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = bytes.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: base) == noErr
        }
        guard copied else { return }
        complete = copy.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            AnnexBResynchronizer.appendAVCC(bytes.bindMemory(to: UInt8.self), lengthBytes: Int(headerLength), to: &frame)
        }
    }
    guard complete else { return }
    encoder.delegate?.encoderDidOutputNALUnit(data: frame, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
}
