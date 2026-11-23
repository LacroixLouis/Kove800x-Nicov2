import Foundation

nonisolated struct WukulucAuthUser: Decodable, Sendable { let id: UUID }

nonisolated struct WukulucSharedRoute: Decodable, Identifiable, Sendable {
    let id: UUID
    let owner_id: UUID
    let name: String
    let activity: String
    let distance_km: Double
    let ascent_m: Double?
    let duration_s: Double?
    let start_lat: Double
    let start_lon: Double
    let point_count: Int
    let created_at: String
    var link: URL { URL(string: "nicomirror://trail/" + id.uuidString)! }
}

nonisolated struct WukulucSharedDocument: Decodable, Sendable {
    let gpx_base64: String
    func data() throws -> Data {
        guard gpx_base64.utf8.count <= 13_333_336 else { throw GPXError.tooLarge }
        guard let data = Data(base64Encoded: gpx_base64) else { throw GPXError.invalid }
        guard data.count <= 10_000_000 else { throw GPXError.tooLarge }
        return data
    }
}
