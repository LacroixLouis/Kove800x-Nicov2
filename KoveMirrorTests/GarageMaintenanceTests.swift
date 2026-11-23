import Testing
import Foundation
@testable import KoveMirror

struct GarageMaintenanceTests {
    @Test func titleComesFromEachMotorcycleNotFromAConstant() throws {
        let first = MotorcycleProfile(brand: "KOVE", model: "800X Rally")
        let second = MotorcycleProfile(brand: "KTM", model: "350 EXC-F")
        #expect(first.title == "KOVE 800X Rally")
        #expect(second.title == "KTM 350 EXC-F")
        #expect(first.id != second.id)
    }

    @Test func eachServiceRecordBelongsToAUniqueMotorcycle() throws {
        let first = MotorcycleProfile(brand: "KOVE", model: "800X Rally")
        let second = MotorcycleProfile(brand: "KTM", model: "350 EXC-F")
        let record = MaintenanceEntry(motorcycleID: first.id,
                                      performedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      mileage: 1000, operation: "Révision", notes: "Filtre changé", photoNames: [])
        #expect(record.motorcycleID == first.id)
        #expect(record.motorcycleID != second.id)
        #expect(record.mileage == 1000)
    }

    @Test func motorbikeAndDealerCanBeSavedAndRead() throws {
        var first = MotorcycleProfile(brand: "Honda", model: "Transalp 600")
        first.photoName = "private-motorcycle-photo.jpg"
        first.dealer = DealerContact(name: "Concessionnaire", email: "atelier@example.com", phone: "", address: "")
        let data = try JSONEncoder().encode(first)
        let recovered = try JSONDecoder().decode(MotorcycleProfile.self, from: data)
        #expect(recovered == first)
        #expect(recovered.photoName == "private-motorcycle-photo.jpg")
        #expect(recovered.dealer.email == "atelier@example.com")
    }
    @Test func legacyMotorcycleDecodesWithoutOwner() throws {
        let original = MotorcycleProfile(brand: "KOVE", model: "800X Rally")
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        old.removeValue(forKey: "owner")
        let recovered = try JSONDecoder().decode(MotorcycleProfile.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(recovered == original)
        #expect(recovered.owner == nil)
    }

    @Test func ownersAreSavedPerMotorcycle() throws {
        var first = MotorcycleProfile(brand: "KOVE", model: "800X Rally")
        let second = MotorcycleProfile(brand: "KTM", model: "350 EXC-F")
        first.owner = MotorcycleOwner(name: "Jean Exemple", street: "1 rue Exemple", postalCode: "01300", city: "Belley", country: "France")
        let recovered = try JSONDecoder().decode([MotorcycleProfile].self, from: JSONEncoder().encode([first, second]))
        #expect(recovered == [first, second])
        #expect(recovered[0].owner?.addressLines == ["1 rue Exemple", "01300 Belley", "France"])
        #expect(recovered[1].owner == nil)
    }

}
