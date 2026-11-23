import Foundation

/// After switching back to ReplayKit, TCP may resume inside a NAL unit.
/// Discard that tail and wait for the next SPS; the existing encoder emits
/// SPS/PPS before every keyframe. Retain only four bytes while waiting.
nonisolated struct AnnexBResynchronizer {
    private var suffix = Data()
    private var synchronized = false

    mutating func reset() {
        suffix.removeAll(keepingCapacity: true)
        synchronized = false
    }

    /// Append the complete length-prefixed sample as Annex B, or leave the frame intact.
    static func appendAVCC(_ bytes: UnsafeBufferPointer<UInt8>, lengthBytes: Int, to frame: inout Data) -> Bool {
        guard [1, 2, 4].contains(lengthBytes), let base = bytes.baseAddress, !bytes.isEmpty else { return false }
        let originalEnd = frame.endIndex
        var offset = 0
        while bytes.count - offset >= lengthBytes {
            var length = 0
            for _ in 0..<lengthBytes {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
            guard length > 0, length <= bytes.count - offset else { break }
            frame.append(contentsOf: [0, 0, 0, 1])
            frame.append(base.advanced(by: offset), count: length)
            offset += length
            if offset == bytes.count { return true }
        }
        frame.removeSubrange(originalEnd..<frame.endIndex)
        return false
    }

    mutating func append(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if synchronized { return data }
        var bytes = Array(suffix)
        bytes.append(contentsOf: data)
        for index in bytes.indices {
            // Accept both standard Annex B prefix lengths.
            let fourByte = index + 4 < bytes.count && bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            let threeByte = index + 3 < bytes.count && bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 1
            let prefix = fourByte ? 4 : (threeByte ? 3 : 0)
            if prefix > 0 && bytes[index + prefix] & 0x1f == 7 {
                synchronized = true
                suffix.removeAll(keepingCapacity: true)
                return Data(bytes[index...])
            }
        }
        suffix = Data(bytes.suffix(4))
        return nil
    }
}
