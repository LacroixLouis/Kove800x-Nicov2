import Foundation
import CoreFoundation

struct MotorcycleOdometer: Codable, Equatable {
    let kilometers: Double
    let peripheralID: UUID
    let receivedAt: Date

    var isValid: Bool {
        kilometers.isFinite && (0...2_000_000).contains(kilometers)
            && receivedAt.timeIntervalSince1970.isFinite
            && abs(receivedAt.timeIntervalSince1970) < 31_536_000_000
    }
}

/// Distances already supported by the TFT's ThinkerRide protocol.
/// Total and trip are separate fields, in tenths of a kilometre.
struct MotorcycleDistancePacket {
    let odometerKilometers: Double?
    let tripKilometers: Double?

    static func decode(_ json: [String: Any]) -> Self? {
        if json["msg_id"] != nil {
            guard json["msg_id"] as? Int == 10, json["item"] as? Int == 2 else { return nil }
        } else if json["item"] != nil, json["item"] as? Int != 2 {
            return nil
        }
        let total = kilometers(json["total"])
        let trip = kilometers(json["subtotal"])
        guard total != nil || trip != nil else { return nil }
        return Self(odometerKilometers: total, tripKilometers: trip)
    }

    private static func kilometers(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, (0...20_000_000).contains(raw), raw.rounded(.towardZero) == raw else { return nil }
        return raw / 10
    }
}

