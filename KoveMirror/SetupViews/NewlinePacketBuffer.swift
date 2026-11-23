import Foundation

/// TCP may split one JSON packet across several receives, or merge several packets.
/// Keep incomplete bytes until the sender's newline delimiter arrives.
struct NewlinePacketBuffer {
    enum PacketError: Error { case tooLarge }
    let maximumPacketBytes: Int
    private var pending = Data()

    init(maximumPacketBytes: Int = 8192) {
        self.maximumPacketBytes = max(1, maximumPacketBytes)
    }

    mutating func append(_ data: Data) throws -> [Data] {
        var packets: [Data] = []
        for byte in data {
            if byte == 0x0A {
                if !pending.isEmpty { packets.append(pending) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < maximumPacketBytes else {
                    pending.removeAll(keepingCapacity: false)
                    throw PacketError.tooLarge
                }
                pending.append(byte)
            }
        }
        return packets
    }
}
