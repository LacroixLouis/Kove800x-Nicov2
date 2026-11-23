import Foundation

/// Empêche de répéter une alerte audio à chaque localisation GPS.
/// L'alerte ne se déclenche que sur une vraie déviation, avec précision GPS suffisante.
struct GPXAlertPolicy {
    private var canAlert = true
    private var previousAlertDate: Date?

    mutating func reset() {
        canAlert = true
        previousAlertDate = nil
    }

    mutating func shouldAnnounce(deviationMeters: Double, gpsAccuracyMeters: Double, now: Date) -> Bool {
        guard deviationMeters.isFinite, gpsAccuracyMeters.isFinite,
              gpsAccuracyMeters >= 0, gpsAccuracyMeters <= 50 else { return false }
        if deviationMeters < 35 {
            canAlert = true
            return false
        }
        guard deviationMeters >= 90, canAlert else { return false }
        if let previousAlertDate, now.timeIntervalSince(previousAlertDate) < 120 { return false }
        previousAlertDate = now
        canAlert = false
        return true
    }
}
