import Foundation
import Combine
import SwiftUI
import UIKit
import PhotosUI
import MessageUI
import UniformTypeIdentifiers

// Local-first garage. Nothing is shared unless the rider taps Partager.
struct DealerContact: Codable, Equatable {
    var name = ""
    var email = ""
    var phone = ""
    var address = ""
}

struct MotorcycleOwner: Codable, Equatable {
    var name = ""
    var street = ""
    var postalCode = ""
    var city = ""
    var country = ""

    var addressLines: [String] {
        let locality = [postalCode, city].filter { !$0.isEmpty }.joined(separator: " ")
        return [street, locality, country].filter { !$0.isEmpty }
    }

    var isEmpty: Bool { name.isEmpty && addressLines.isEmpty }
}

struct MotorcycleProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var brand: String
    var model: String
    var year = ""
    var registration = ""
    var vin = ""
    var photoName: String?
    var dealer = DealerContact()
    // Optional for decoding garages created before owner details were introduced.
    var owner: MotorcycleOwner? = nil
    var addedAt = Date()

    var title: String { "\(brand) \(model)".trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct MaintenanceEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var motorcycleID: UUID
    var performedAt: Date
    var mileage: Int
    var operation: String
    var notes: String
    var photoNames: [String]
    var createdAt = Date()
}

enum InvoiceCategory: String, Codable, CaseIterable, Identifiable {
    case purchase, service, accessories
    var id: String { rawValue }
    var title: String {
        switch self {
        case .purchase: return "Achat de la moto"
        case .service: return "Entretien"
        case .accessories: return "Accessoires"
        }
    }
}

struct GarageInvoice: Codable, Identifiable, Equatable {
    var id = UUID()
    let motorcycleID: UUID
    let category: InvoiceCategory
    let date: Date
    let title: String
    let fileName: String
}

@MainActor
final class MaintenanceGarage: ObservableObject {
    static let shared = MaintenanceGarage()

    @Published private(set) var motorcycles: [MotorcycleProfile] = []
    @Published private(set) var entries: [MaintenanceEntry] = []
    @Published private(set) var invoices: [GarageInvoice] = []
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "doubleInterface.garage.selectedMoto") }
    }
    @Published var errorMessage: String?

    private let root: URL
    private var database: URL { root.appendingPathComponent("garage.json") }
    private var imagesFolder: URL { root.appendingPathComponent("Photos", isDirectory: true) }

    private var invoiceFolder: URL { root.appendingPathComponent("Invoices", isDirectory: true) }

    private struct Archive: Codable {
        var motorcycles: [MotorcycleProfile]
        var entries: [MaintenanceEntry]
        var invoices: [GarageInvoice]?
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("DoubleInterfaceGarage", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: database.path) {
                let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: database))
                motorcycles = saved.motorcycles
                entries = saved.entries
                invoices = saved.invoices ?? []
            }
        } catch {
            errorMessage = "Impossible de lire le garage : \(error.localizedDescription)"
        }
        if let saved = UserDefaults.standard.string(forKey: "doubleInterface.garage.selectedMoto"),
           let id = UUID(uuidString: saved), motorcycles.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = motorcycles.first?.id
        }
    }

    var activeMotorcycle: MotorcycleProfile? { motorcycles.first(where: { $0.id == selectedID }) }

    func history(for motorcycleID: UUID) -> [MaintenanceEntry] {
        entries.filter { $0.motorcycleID == motorcycleID }
            .sorted { $0.performedAt == $1.performedAt ? $0.createdAt > $1.createdAt : $0.performedAt > $1.performedAt }
    }

    func latestMileage(for motorcycleID: UUID) -> Int? {
        history(for: motorcycleID).map(\.mileage).max()
    }

    @discardableResult
    func saveMotorcycle(_ moto: MotorcycleProfile, newPhoto: UIImage?) -> Bool {
        let previous = motorcycles
        var createdPhoto: String?
        do {
            var updated = moto
            if let newPhoto {
                let filename = try storePhoto(newPhoto)
                createdPhoto = filename
                updated.photoName = filename
            }
            let oldPhoto = motorcycles.first(where: { $0.id == moto.id })?.photoName
            if let index = motorcycles.firstIndex(where: { $0.id == moto.id }) {
                motorcycles[index] = updated
            } else {
                motorcycles.append(updated)
            }
            try persist()
            selectedID = updated.id
            if let oldPhoto, oldPhoto != updated.photoName { removePhoto(oldPhoto) }
            return true
        } catch {
            motorcycles = previous
            if let createdPhoto { removePhoto(createdPhoto) }
            errorMessage = "Enregistrement de la moto impossible : \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveDealer(_ dealer: DealerContact, motorcycleID: UUID) -> Bool {
        guard let index = motorcycles.firstIndex(where: { $0.id == motorcycleID }) else { return false }
        let previous = motorcycles[index].dealer
        motorcycles[index].dealer = dealer
        do { try persist(); return true }
        catch {
            motorcycles[index].dealer = previous
            errorMessage = "Contact non enregistré : \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addEntry(motorcycleID: UUID, date: Date, mileage: Int, operation: String,
                  notes: String, photos: [UIImage]) -> Bool {
        guard motorcycles.contains(where: { $0.id == motorcycleID }) else { return false }
        var stored: [String] = []
        let entryID = UUID()
        do {
            for photo in photos.prefix(6) { stored.append(try storePhoto(photo)) }
            entries.append(MaintenanceEntry(id: entryID, motorcycleID: motorcycleID, performedAt: date,
                                            mileage: mileage, operation: operation,
                                            notes: notes, photoNames: stored))
            try persist()
            return true
        } catch {
            entries.removeAll { $0.id == entryID }
            for filename in stored { removePhoto(filename) }
            errorMessage = "Fiche non enregistrée : \(error.localizedDescription)"
            return false
        }
    }

    func deleteEntry(_ entry: MaintenanceEntry) {
        let previous = entries
        entries.removeAll { $0.id == entry.id }
        do {
            try persist()
            for photo in entry.photoNames { removePhoto(photo) }
        } catch {
            entries = previous
            errorMessage = "Suppression impossible : \(error.localizedDescription)"
        }
    }

    func invoices(for motorcycleID: UUID, category: InvoiceCategory) -> [GarageInvoice] {
        invoices.filter { $0.motorcycleID == motorcycleID && $0.category == category }
            .sorted { $0.date > $1.date }
    }

    func invoiceURL(_ invoice: GarageInvoice) -> URL {
        invoiceFolder.appendingPathComponent(invoice.fileName)
    }

    func addInvoice(motorcycleID: UUID, category: InvoiceCategory, date: Date,
                    title: String, data: Data, type: UTType) throws {
        guard motorcycles.contains(where: { $0.id == motorcycleID }), !data.isEmpty,
              data.count <= 25 * 1024 * 1024 else {
            throw NSError(domain: "Garage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Document invalide ou supérieur à 25 Mo."])
        }
        let ext: String
        if type.conforms(to: .pdf), data.starts(with: Data("%PDF-".utf8)) { ext = "pdf" }
        else if type.conforms(to: .image), UIImage(data: data) != nil { ext = type.preferredFilenameExtension ?? "jpg" }
        else { throw NSError(domain: "Garage", code: 4, userInfo: [NSLocalizedDescriptionKey: "Choisis une photo ou un PDF valide."]) }
        let id = UUID()
        let invoice = GarageInvoice(id: id, motorcycleID: motorcycleID, category: category,
                                    date: date, title: title, fileName: id.uuidString + "." + ext)
        try FileManager.default.createDirectory(at: invoiceFolder, withIntermediateDirectories: true)
        let url = invoiceURL(invoice)
        try data.write(to: url, options: .atomic)
        invoices.append(invoice)
        do { try persist() } catch {
            invoices.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func deleteInvoice(_ invoice: GarageInvoice) throws {
        let previous = invoices
        invoices.removeAll { $0.id == invoice.id }
        do { try persist() } catch { invoices = previous; throw error }
        try? FileManager.default.removeItem(at: invoiceURL(invoice))
    }

    func photo(named name: String?) -> UIImage? {
        guard let name, !name.contains("/"), !name.contains("..") else { return nil }
        return UIImage(contentsOfFile: imagesFolder.appendingPathComponent(name).path)
    }

    private func storePhoto(_ photo: UIImage) throws -> String {
        let name = UUID().uuidString + ".jpg"
        guard let bytes = photo.jpegData(compressionQuality: 0.79) else {
            throw NSError(domain: "Garage", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Format de photo non reconnu"])
        }
        try bytes.write(to: imagesFolder.appendingPathComponent(name), options: .atomic)
        return name
    }

    private func removePhoto(_ name: String) {
        guard !name.contains("/"), !name.contains("..") else { return }
        try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(name))
    }

    private func persist() throws {
        let snapshot = Archive(motorcycles: motorcycles, entries: entries, invoices: invoices)
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: database, options: .atomic)
    }
}

// The dealer receives a real PDF with the user's own photographs embedded in it.
@MainActor
enum GaragePDF {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let green = UIColor(red: 0.11, green: 0.60, blue: 0.43, alpha: 1)
    private static let ink = UIColor(red: 0.06, green: 0.14, blue: 0.20, alpha: 1)

    static func make(moto: MotorcycleProfile, entries: [MaintenanceEntry], store: MaintenanceGarage) throws -> URL {
        guard entries.count == 1, entries.first?.motorcycleID == moto.id else {
            throw NSError(domain: "Garage", code: 5, userInfo: [NSLocalizedDescriptionKey: "Une seule intervention de cette moto par document."])
        }
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { context in
            context.beginPage()
            header(moto.title, subtitle: "FICHE D’ENTRETIEN", context: context)
            draw("Marque : \(moto.brand)", at: CGRect(x: 42, y: 138, width: 500, height: 24), size: 14)
            draw("Modèle : \(moto.model)", at: CGRect(x: 42, y: 168, width: 500, height: 24), size: 14)
            draw("Année : \(moto.year.isEmpty ? "—" : moto.year)", at: CGRect(x: 42, y: 198, width: 500, height: 24), size: 14)
            draw("Immatriculation : \(moto.registration.isEmpty ? "—" : moto.registration)", at: CGRect(x: 42, y: 228, width: 500, height: 24), size: 14)
            draw("Numéro de série : \(moto.vin.isEmpty ? "—" : moto.vin)", at: CGRect(x: 42, y: 258, width: 510, height: 24), size: 14)
            let owner = moto.owner ?? MotorcycleOwner()
            draw("PROPRIÉTAIRE", at: CGRect(x: 42, y: 294, width: 510, height: 22), size: 12, bold: true, color: green)
            let ownerText = ([owner.name.isEmpty ? "Nom : non renseigné" : "Nom : \(owner.name)", "Adresse :"] + (owner.addressLines.isEmpty ? ["Non renseignée"] : owner.addressLines)).joined(separator: "\n")
            let ownerLines = wrappedLines(ownerText, width: 510, fontSize: 13)
            draw(ownerLines.prefix(7).joined(separator: "\n"),
                 at: CGRect(x: 42, y: 318, width: 510, height: 117), size: 13)
            if let photo = store.photo(named: moto.photoName) {
                drawImage(photo, in: CGRect(x: 42, y: 445, width: 510, height: 145))
            }
            draw("\(entries.count) intervention(s) · Édité le \(Date.now.formatted(date: .numeric, time: .shortened))",
                 at: CGRect(x: 42, y: 605, width: 510, height: 34), size: 14)
            if !moto.dealer.name.isEmpty {
                draw("Concessionnaire : \(moto.dealer.name)",
                     at: CGRect(x: 42, y: 655, width: 510, height: 24), size: 13)
            }
            var ownerOffset = 7
            while ownerOffset < ownerLines.count {
                context.beginPage()
                header(moto.title, subtitle: "COORDONNÉES DU PROPRIÉTAIRE (SUITE)", context: context)
                draw(ownerLines.dropFirst(ownerOffset).prefix(36).joined(separator: "\n"),
                     at: CGRect(x: 42, y: 135, width: 510, height: 620), size: 13)
                ownerOffset += 36
            }
            for entry in entries {
                context.beginPage()
                header(moto.title, subtitle: "FICHE D’ENTRETIEN", context: context)
                draw("Date : \(entry.performedAt.formatted(date: .long, time: .omitted))",
                     at: CGRect(x: 42, y: 133, width: 510, height: 30), size: 15)
                draw("Kilométrage : \(entry.mileage.formatted()) km",
                     at: CGRect(x: 42, y: 169, width: 510, height: 30), size: 15)
                draw(entry.operation, at: CGRect(x: 42, y: 214, width: 510, height: 55), size: 20, bold: true)
                let noteLines = wrappedLines(entry.notes, width: 510, fontSize: 13)
                draw(noteLines.prefix(7).joined(separator: "\n"),
                     at: CGRect(x: 42, y: 282, width: 510, height: 132), size: 13)
                for (index, name) in entry.photoNames.prefix(6).enumerated() {
                    guard let photo = store.photo(named: name) else { continue }
                    let x = 42 + CGFloat(index % 2) * 260
                    let y = 433 + CGFloat(index / 2) * 125
                    drawImage(photo, in: CGRect(x: x, y: y, width: 248, height: 115))
                }
                let continued = Array(noteLines.dropFirst(7))
                if !continued.isEmpty {
                    var offset = 0
                    while offset < continued.count {
                        context.beginPage()
                        header(moto.title, subtitle: "NOTES D’ENTRETIEN (SUITE)", context: context)
                        draw(entry.operation, at: CGRect(x: 42, y: 133, width: 510, height: 35),
                             size: 17, bold: true)
                        draw(Array(continued.dropFirst(offset).prefix(36)).joined(separator: "\n"),
                             at: CGRect(x: 42, y: 188, width: 510, height: 600), size: 13)
                        offset += 36
                    }
                }
            }
        }
        let dateLabel = entries.first?.performedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)) ?? "date"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Entretien_\(dateLabel)_\(entries.first?.mileage ?? 0)km_\(UUID().uuidString).pdf")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func header(_ title: String, subtitle: String, context: UIGraphicsPDFRendererContext) {
        ink.setFill(); context.fill(CGRect(x: 0, y: 0, width: page.width, height: 112))
        green.setFill(); context.fill(CGRect(x: 0, y: 108, width: page.width, height: 4))
        draw(subtitle, at: CGRect(x: 42, y: 20, width: 500, height: 24), size: 12, bold: true, color: green)
        draw(title, at: CGRect(x: 42, y: 49, width: 510, height: 48), size: 25, bold: true, color: .white)
    }

    private static func draw(_ text: String, at rect: CGRect, size: CGFloat,
                             bold: Bool = false, color: UIColor = ink) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: rect, withAttributes: [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: color, .paragraphStyle: style
        ])
    }

    // Explicit line wrapping prevents long notes being silently truncated in exported PDFs.
    private static func wrappedLines(_ text: String, width: CGFloat, fontSize: CGFloat) -> [String] {
        let font = UIFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let candidate = line.isEmpty ? word : "\(line) \(word)"
                if (candidate as NSString).size(withAttributes: attributes).width <= width || line.isEmpty {
                    line = candidate
                } else {
                    lines.append(line)
                    line = word
                }
            }
            lines.append(line)
        }
        return lines
    }

    private static func drawImage(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let fit = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2,
                              width: fit.width, height: fit.height))
    }
}

struct GarageSharePayload: Identifiable {
    let id = UUID()
    let pdf: URL
    let recipient: String
    let subject: String
}

struct GarageActivitySheet: UIViewControllerRepresentable {
    var file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct GarageMailSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let payload: GarageSharePayload

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var parent: GarageMailSheet
        init(parent: GarageMailSheet) { self.parent = parent }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.dismiss()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([payload.recipient])
        composer.setSubject(payload.subject)
        composer.setMessageBody("Bonjour,\n\nVeuillez trouver en pièce jointe la fiche d’entretien de ma moto.\n\nCordialement", isHTML: false)
        if let data = try? Data(contentsOf: payload.pdf) {
            composer.addAttachmentData(data, mimeType: "application/pdf", fileName: payload.pdf.lastPathComponent)
        }
        return composer
    }
    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
}
