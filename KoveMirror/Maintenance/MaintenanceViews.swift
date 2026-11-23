import SwiftUI
import UIKit
import PhotosUI
import MessageUI
import UniformTypeIdentifiers
import QuickLook

private enum GarageUI {
    static let accent = Color(hex: "31DE93")
    static let back = Color(hex: "07131F")
    static let surface = Color(hex: "142536")
    static let border = Color.white.opacity(0.14)
    static let muted = Color(hex: "BBD0DD")
}

private enum GarageModal: Identifiable {
    case newMotorcycle, editMotorcycle, dealer, newEntry, invoices(UUID), entry(UUID)
    var id: String {
        switch self {
        case .newMotorcycle: return "new-motorcycle"
        case .editMotorcycle: return "edit-motorcycle"
        case .dealer: return "dealer"
        case .newEntry: return "new-entry"
        case .invoices(let id): return "invoices-\(id.uuidString)"
        case .entry(let id): return "entry-\(id.uuidString)"
        }
    }
}

struct MaintenanceHomeView: View {
    @ObservedObject var bleController: BleController
    @StateObject private var garage = MaintenanceGarage.shared
    @Environment(\.dismiss) private var dismiss
    @State private var modal: GarageModal?

    private var active: MotorcycleProfile? { garage.activeMotorcycle }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let moto = active {
                        motorcycleHeader(moto)
                        controls(moto)
                        invoiceShortcut(moto)
                        ownerSummary(moto)
                        dealerSummary(moto)
                        history(moto)
                    } else {
                        emptyGarage
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 35)
            }
            .background(GarageUI.back.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Mon garage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("garage.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Ajouter une moto", systemImage: "plus.circle") { modal = .newMotorcycle }
                        if active != nil {
                            Button("Modifier la moto", systemImage: "pencil") { modal = .editMotorcycle }
                            Button("Fiche concessionnaire", systemImage: "building.2") { modal = .dealer }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Options du garage")
                }
            }
            .toolbarBackground(GarageUI.back, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(GarageUI.accent)
            .sheet(item: $modal) { target in
                switch target {
                case .newMotorcycle: MotorcycleFormView(motorcycle: nil, garage: garage)
                case .editMotorcycle: MotorcycleFormView(motorcycle: active, garage: garage)
                case .dealer:
                    if let active { DealerFormView(motorcycle: active, garage: garage) }
                case .newEntry:
                    if let active {
                        MaintenanceEntryFormView(motorcycle: active, garage: garage, bleController: bleController)
                    }
                case .invoices(let id):
                    if let moto = garage.motorcycles.first(where: { $0.id == id }) {
                        GarageInvoicesView(moto: moto, garage: garage)
                    }
                case .entry(let id):
                    if let entry = garage.entries.first(where: { $0.id == id }),
                       let moto = garage.motorcycles.first(where: { $0.id == entry.motorcycleID }) {
                        MaintenanceEntryDetailView(moto: moto, entry: entry, garage: garage)
                    }
                }
            }
            .alert("Journal d’entretien", isPresented: Binding(
                get: { garage.errorMessage != nil },
                set: { if !$0 { garage.errorMessage = nil } }
            )) { Button("OK", role: .cancel) { garage.errorMessage = nil } }
                message: { Text(garage.errorMessage ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyGarage: some View {
        VStack(spacing: 20) {
            Image(systemName: "motorcycle")
                .font(.system(size: 70, weight: .ultraLight))
                .foregroundStyle(GarageUI.accent)
                .frame(height: 130)
            Text("Bienvenue dans ton garage").font(.title2.bold())
            Text("Ajoute ta première moto. Sa marque et son modèle deviendront le titre de sa fiche. Chaque moto aura sa propre photo et son historique.")
                .multilineTextAlignment(.center)
                .foregroundStyle(GarageUI.muted)
            Button { modal = .newMotorcycle } label: {
                Label("Ajouter une moto", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GaragePrimaryButton())
            .accessibilityIdentifier("garage.addFirstMotorcycle")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 22))
        .padding(.top, 30)
    }

    private func motorcycleHeader(_ moto: MotorcycleProfile) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = garage.photo(named: moto.photoName) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [.init(hex: "1A4052"), GarageUI.back],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "motorcycle")
                            .font(.system(size: 100, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.24))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 225)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.88)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    Text("JOURNAL D’ENTRETIEN")
                        .font(.caption.bold()).foregroundStyle(GarageUI.accent)
                        .tracking(1.4)
                    Text(moto.title)
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if moto.photoName == nil {
                        Button("Ajouter ma photo", systemImage: "camera.fill") {
                            modal = .editMotorcycle
                        }
                        .font(.caption.bold())
                    }
                }
                .padding(18)
            }
            .frame(height: 225)
            Menu {
                ForEach(garage.motorcycles) { candidate in
                    Button {
                        garage.selectedID = candidate.id
                    } label: {
                        if candidate.id == moto.id {
                            Label(candidate.title, systemImage: "checkmark.circle.fill")
                        } else {
                            Text(candidate.title)
                        }
                    }
                }
                Divider()
                Button("Ajouter une moto", systemImage: "plus.circle.fill") { modal = .newMotorcycle }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "motorcycle")
                    Text("Moto active : \(moto.title)")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .padding(16)
                .background(GarageUI.surface)
            }
            .accessibilityIdentifier("garage.selectMotorcycle")
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(GarageUI.border))
    }

    private func controls(_ moto: MotorcycleProfile) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statTile("Interventions", value: "\(garage.history(for: moto.id).count)", icon: "wrench.adjustable")
                statTile("Dernier km", value: garage.latestMileage(for: moto.id).map { "\($0.formatted())" } ?? "—", icon: "gauge.with.dots.needle.33percent")
            }
            if moto.brand.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Kove") == .orderedSame,
               bleController.connectionState == .connected,
               let odo = bleController.odoDistanceKm, odo.isFinite, odo >= 0, odo <= Double(Int.max) {
                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text("Compteur Kove connecté : \(Int(odo.rounded()).formatted()) km")
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(GarageUI.accent)
            }
            Button { modal = .newEntry } label: {
                Label("Nouvelle fiche d’entretien", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GaragePrimaryButton())
            .accessibilityIdentifier("garage.addEntry")
        }
    }

    private func statTile(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(GarageUI.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(GarageUI.muted)
                Text(value).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(13)
        .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 15))
    }

    private func ownerSummary(_ moto: MotorcycleProfile) -> some View {
        let owner = moto.owner ?? MotorcycleOwner()
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Propriétaire", systemImage: "person.crop.circle")
                    .font(.headline)
                Spacer()
                Button("Modifier") { modal = .editMotorcycle }.font(.caption.bold())
                    .accessibilityIdentifier("garage.editOwner")
            }
            if owner.isEmpty {
                Text("Nom et adresse non renseignés")
                    .font(.subheadline).foregroundStyle(GarageUI.muted)
                Button("Renseigner le propriétaire") { modal = .editMotorcycle }
                    .font(.subheadline.bold())
            } else {
                if !owner.name.isEmpty { Text(owner.name).font(.headline) }
                if !owner.addressLines.isEmpty {
                    Text(owner.addressLines.joined(separator: "\n"))
                        .font(.subheadline).foregroundStyle(GarageUI.muted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func dealerSummary(_ moto: MotorcycleProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Concessionnaire", systemImage: "building.2.crop.circle.fill")
                    .font(.headline)
                Spacer()
                Button("Modifier") { modal = .dealer }.font(.caption.bold())
            }
            if moto.dealer.name.isEmpty {
                Text("Renseigner le nom et l’adresse e-mail du concessionnaire pour préparer l’envoi de tes fiches.")
                    .font(.subheadline).foregroundStyle(GarageUI.muted)
                Button("Créer la fiche contact", systemImage: "plus") { modal = .dealer }
                    .font(.subheadline.bold())
            } else {
                Text(moto.dealer.name).font(.headline)
                if !moto.dealer.email.isEmpty {
                    Label(moto.dealer.email, systemImage: "envelope").font(.subheadline)
                }

            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func history(_ moto: MotorcycleProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Historique").font(.title3.bold())
                Spacer()
                Text("\(garage.history(for: moto.id).count) fiche(s)")
                    .font(.caption).foregroundStyle(GarageUI.muted)
            }
            let records = garage.history(for: moto.id)
            if records.isEmpty {
                Text("Aucune intervention pour cette moto. Ajoute ta première révision, vidange ou réparation.")
                    .font(.subheadline).foregroundStyle(GarageUI.muted)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(records) { entry in
                    Button { modal = .entry(entry.id) } label: {
                        HStack(spacing: 12) {
                            if let first = entry.photoNames.first, let image = garage.photo(named: first) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 75, height: 75).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 11))
                            } else {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.title2).foregroundStyle(GarageUI.accent)
                                    .frame(width: 75, height: 75)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.operation).font(.headline).lineLimit(2)
                                Text(entry.performedAt.formatted(date: .numeric, time: .omitted) + " · \(entry.mileage.formatted()) km")
                                    .font(.subheadline).foregroundStyle(GarageUI.muted)
                                Label("\(entry.photoNames.count) photo(s)", systemImage: "camera")
                                    .font(.caption).foregroundStyle(GarageUI.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.bold()).foregroundStyle(GarageUI.accent)
                        }
                        .padding(10)
                        .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func invoiceShortcut(_ moto: MotorcycleProfile) -> some View {
        Button { modal = .invoices(moto.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(GarageUI.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Factures").font(.headline)
                    Text("Achat · Entretien · Accessoires").font(.caption).foregroundStyle(GarageUI.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(16).background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

}

private struct GaragePrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).bold())
            .foregroundStyle(GarageUI.back)
            .padding(.vertical, 15)
            .padding(.horizontal, 12)
            .background(GarageUI.accent, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct GarageOutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .padding(14)
            .foregroundStyle(GarageUI.accent)
            .background(GarageUI.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct GarageSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased()).font(.caption.bold()).tracking(1.1).foregroundStyle(GarageUI.accent)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GarageUI.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MotorcycleFormView: View {
    let motorcycle: MotorcycleProfile?
    @ObservedObject var garage: MaintenanceGarage
    @Environment(\.dismiss) private var dismiss
    @State private var brand: String
    @State private var model: String
    @State private var year: String
    @State private var registration: String
    @State private var vin: String
    @State private var owner: MotorcycleOwner
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var newPhoto: UIImage?
    @State private var photoError = ""

    init(motorcycle: MotorcycleProfile?, garage: MaintenanceGarage) {
        self.motorcycle = motorcycle
        self.garage = garage
        _brand = State(initialValue: motorcycle?.brand ?? "")
        _model = State(initialValue: motorcycle?.model ?? "")
        _year = State(initialValue: motorcycle?.year ?? "")
        _registration = State(initialValue: motorcycle?.registration ?? "")
        _vin = State(initialValue: motorcycle?.vin ?? "")
        _owner = State(initialValue: motorcycle?.owner ?? MotorcycleOwner())
    }

    private var canSave: Bool {
        !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Titre de la fiche") {
                    TextField("Marque (ex. : KOVE)", text: $brand)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("garage.brand")
                    TextField("Type / Modèle (ex. : 800X Rally)", text: $model)
                        .accessibilityIdentifier("garage.model")
                    Text(canSave ? "Titre : \(brand.trimmingCharacters(in: .whitespacesAndNewlines)) \(model.trimmingCharacters(in: .whitespacesAndNewlines))" : "Renseigne la marque et le modèle")
                        .font(.caption).foregroundStyle(GarageUI.accent)
                }
                Section("Ma photo de la moto") {
                    Group {
                        if let image = newPhoto ?? garage.photo(named: motorcycle?.photoName) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 195)
                                .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Image(systemName: "motorcycle")
                                .font(.system(size: 65))
                                .foregroundStyle(GarageUI.muted)
                                .frame(maxWidth: .infinity).frame(height: 140)
                        }
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                        Label("Choisir ma photo", systemImage: "photo.on.rectangle.angled")
                    }
                    if !photoError.isEmpty { Text(photoError).foregroundStyle(.red).font(.caption) }
                }
                Section {
                    TextField("Nom et prénom", text: $owner.name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("garage.owner.name")
                    TextField("Adresse (numéro, rue, complément)", text: $owner.street, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("garage.owner.street")
                    TextField("Code postal", text: $owner.postalCode)
                        .textContentType(.postalCode)
                        .accessibilityIdentifier("garage.owner.postalCode")
                    TextField("Ville", text: $owner.city)
                        .textContentType(.addressCity)
                        .accessibilityIdentifier("garage.owner.city")
                    TextField("Pays", text: $owner.country)
                        .textContentType(.countryName)
                        .accessibilityIdentifier("garage.owner.country")
                } header: {
                    Text("Propriétaire de la moto")
                } footer: {
                    Text("Facultatif. Ces coordonnées restent dans le garage et figurent sur les fiches d’entretien que tu choisis de partager.")
                }
                Section("Identification (facultatif)") {
                    TextField("Année", text: $year).keyboardType(.numberPad)
                    TextField("Immatriculation", text: $registration)
                        .textInputAutocapitalization(.characters)
                    TextField("Numéro de série / VIN", text: $vin)
                        .textInputAutocapitalization(.characters)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GarageUI.back)
            .navigationTitle(motorcycle == nil ? "Ajouter une moto" : "Modifier la moto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.disabled(!canSave)
                }
            }
            .onChange(of: selectedPhoto) { _, selection in
                guard let selection else { return }
                Task {
                    do {
                        guard let bytes = try await selection.loadTransferable(type: Data.self),
                              let photo = UIImage(data: bytes) else { throw CocoaError(.fileReadCorruptFile) }
                        await MainActor.run { newPhoto = photo; photoError = "" }
                    } catch {
                        await MainActor.run { photoError = "Impossible de lire cette photo." }
                    }
                }
            }
        }
        .tint(GarageUI.accent)
        .preferredColorScheme(.dark)
    }

    private func save() {
        var updated = motorcycle ?? MotorcycleProfile(brand: "", model: "")
        updated.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.year = year.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.registration = registration.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.vin = vin.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedOwner = MotorcycleOwner(
            name: owner.name.trimmingCharacters(in: .whitespacesAndNewlines),
            street: owner.street.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: owner.postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
            city: owner.city.trimmingCharacters(in: .whitespacesAndNewlines),
            country: owner.country.trimmingCharacters(in: .whitespacesAndNewlines))
        updated.owner = cleanedOwner.isEmpty ? nil : cleanedOwner
        if garage.saveMotorcycle(updated, newPhoto: newPhoto) { dismiss() }
    }
}

struct DealerFormView: View {
    let motorcycle: MotorcycleProfile
    @ObservedObject var garage: MaintenanceGarage
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var email: String
    @State private var phone: String
    @State private var address: String

    init(motorcycle: MotorcycleProfile, garage: MaintenanceGarage) {
        self.motorcycle = motorcycle
        self.garage = garage
        _name = State(initialValue: motorcycle.dealer.name)
        _email = State(initialValue: motorcycle.dealer.email)
        _phone = State(initialValue: motorcycle.dealer.phone)
        _address = State(initialValue: motorcycle.dealer.address)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Concessionnaire · \(motorcycle.title)") {
                    TextField("Nom du concessionnaire", text: $name)
                    TextField("Adresse e-mail", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Téléphone", text: $phone).keyboardType(.phonePad)
                    TextField("Adresse", text: $address, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Text("Le concessionnaire est associé uniquement à cette moto. Lors du partage, son adresse e-mail sera proposée automatiquement si Mail est configuré sur l’iPhone.")
                        .font(.footnote).foregroundStyle(GarageUI.muted)
                }
            }
            .scrollContentBackground(.hidden).background(GarageUI.back)
            .navigationTitle("Fiche concessionnaire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        let dealer = DealerContact(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   address: address.trimmingCharacters(in: .whitespacesAndNewlines))
                        if garage.saveDealer(dealer, motorcycleID: motorcycle.id) { dismiss() }
                    }
                }
            }
        }
        .tint(GarageUI.accent).preferredColorScheme(.dark)
    }
}

private struct GarageDraftPhoto: Identifiable {
    var id = UUID()
    var image: UIImage
}

struct MaintenanceEntryFormView: View {
    let motorcycle: MotorcycleProfile
    @ObservedObject var garage: MaintenanceGarage
    @ObservedObject var bleController: BleController
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var mileage: String
    @State private var operation = ""
    @State private var notes = ""
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var photos: [GarageDraftPhoto] = []
    @State private var photoError = ""

    init(motorcycle: MotorcycleProfile, garage: MaintenanceGarage, bleController: BleController) {
        self.motorcycle = motorcycle
        self.garage = garage
        self.bleController = bleController
        let live = motorcycle.brand.localizedCaseInsensitiveCompare("Kove") == .orderedSame &&
                   bleController.connectionState == .connected ? bleController.odoDistanceKm : nil
        let suggested: Int?
        if let live, live.isFinite, live >= 0, live <= Double(Int.max) {
            suggested = Int(live.rounded())
        } else {
            suggested = garage.latestMileage(for: motorcycle.id)
        }
        _mileage = State(initialValue: suggested.map(String.init) ?? "")
    }
    private var parsedMileage: Int? {
        guard let km = Int(mileage.trimmingCharacters(in: .whitespacesAndNewlines)), km >= 0 else { return nil }
        return km
    }
    private var canSave: Bool { parsedMileage != nil && !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "motorcycle").foregroundStyle(GarageUI.accent)
                        VStack(alignment: .leading) {
                            Text(motorcycle.title).font(.headline)
                            Text("Nouvelle fiche d’entretien").font(.caption).foregroundStyle(GarageUI.muted)
                        }
                    }
                }
                Section("Intervention") {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                    HStack {
                        TextField("Kilométrage", text: $mileage).keyboardType(.numberPad)
                            .accessibilityIdentifier("garage.entry.mileage")
                        Text("km").foregroundStyle(GarageUI.muted)
                    }
                    if motorcycle.brand.localizedCaseInsensitiveCompare("Kove") == .orderedSame,
                       bleController.connectionState == .connected,
                       let live = bleController.odoDistanceKm, live.isFinite, live >= 0, live <= Double(Int.max) {
                        Button("Reprendre le kilométrage du compteur (\(Int(live.rounded())) km)", systemImage: "arrow.clockwise") {
                            mileage = String(Int(live.rounded()))
                        }
                        .font(.caption)
                    }
                    TextField("Opération (vidange, révision…)", text: $operation)
                        .accessibilityIdentifier("garage.entry.operation")
                    TextField("Notes, pièces et observations", text: $notes, axis: .vertical)
                        .lineLimit(3...7)
                }
                Section("Photos (\(photos.count)/6)") {
                    PhotosPicker(selection: $photoSelections, maxSelectionCount: max(1, 6 - photos.count),
                                 matching: .images, photoLibrary: .shared()) {
                        Label("Ajouter des photos", systemImage: "camera.fill")
                    }
                    .disabled(photos.count >= 6)
                    if !photoError.isEmpty { Text(photoError).foregroundStyle(.red).font(.caption) }
                    if !photos.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(photos) { item in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: item.image).resizable().scaledToFill()
                                        .frame(height: 99).frame(maxWidth: .infinity)
                                        .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                                    Button {
                                        photos.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white).background(.black.opacity(0.7), in: Circle())
                                    }
                                    .padding(4)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("La fiche et les photos restent sur ton iPhone. Le partage au concessionnaire se fait uniquement lorsque tu le demandes.")
                        .font(.footnote).foregroundStyle(GarageUI.muted)
                }
            }
            .scrollContentBackground(.hidden).background(GarageUI.back)
            .navigationTitle("Nouvelle entrée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.disabled(!canSave)
                        .accessibilityIdentifier("garage.entry.save")
                }
            }
            .onChange(of: photoSelections) { _, selections in
                guard !selections.isEmpty else { return }
                Task {
                    var loaded: [GarageDraftPhoto] = []
                    for selection in selections {
                        if let bytes = try? await selection.loadTransferable(type: Data.self),
                           let image = UIImage(data: bytes) {
                            loaded.append(GarageDraftPhoto(image: image))
                        }
                    }
                    await MainActor.run {
                        photos.append(contentsOf: loaded.prefix(max(0, 6 - photos.count)))
                        if loaded.count != selections.count { photoError = "Certaines photos n’ont pas pu être lues." }
                        photoSelections = []
                    }
                }
            }
        }
        .tint(GarageUI.accent).preferredColorScheme(.dark)
    }

    private func save() {
        guard let km = parsedMileage else { return }
        if garage.addEntry(motorcycleID: motorcycle.id, date: date, mileage: km,
                           operation: operation.trimmingCharacters(in: .whitespacesAndNewlines),
                           notes: notes, photos: photos.map(\.image)) { dismiss() }
    }
}

struct MaintenanceEntryDetailView: View {
    let moto: MotorcycleProfile
    let entry: MaintenanceEntry
    @ObservedObject var garage: MaintenanceGarage
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: GarageSharePayload?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GarageSection(title: moto.title) {
                        Text(entry.operation).font(.title2.bold())
                        Label(entry.performedAt.formatted(date: .long, time: .omitted), systemImage: "calendar")
                        Label("\(entry.mileage.formatted()) km", systemImage: "gauge.with.dots.needle.33percent")
                        if !entry.notes.isEmpty {
                            Divider()
                            Text(entry.notes)
                        }
                    }
                    if !entry.photoNames.isEmpty {
                        GarageSection(title: "Photos") {
                            ForEach(entry.photoNames, id: \.self) { name in
                                if let image = garage.photo(named: name) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
                    Button { share() } label: {
                        Label("Envoyer au concessionnaire", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GaragePrimaryButton())
                    if let owner = moto.owner, !owner.isEmpty {
                        Text("Le PDF contient aussi les coordonnées du propriétaire de cette moto.")
                            .font(.caption).foregroundStyle(GarageUI.muted)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Supprimer cette fiche", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(12)
                }
                .padding(16)
            }
            .background(GarageUI.back.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Fiche d’entretien")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } } }
            .confirmationDialog("Supprimer définitivement cette fiche et ses photos ?", isPresented: $confirmDelete) {
                Button("Supprimer", role: .destructive) {
                    garage.deleteEntry(entry)
                    dismiss()
                }
            }
            .sheet(item: $sharing) { payload in
                if !payload.recipient.isEmpty && MFMailComposeViewController.canSendMail() {
                    GarageMailSheet(payload: payload)
                } else {
                    GarageActivitySheet(file: payload.pdf)
                }
            }
        }
        .tint(GarageUI.accent).preferredColorScheme(.dark)
    }

    private func share() {
        do {
            let url = try GaragePDF.make(moto: moto, entries: [entry], store: garage)
            sharing = GarageSharePayload(pdf: url, recipient: moto.dealer.email.trimmingCharacters(in: .whitespacesAndNewlines),
                                         subject: "\(moto.title) – \(entry.operation) – \(entry.mileage) km – \(entry.performedAt.formatted(date: .numeric, time: .omitted))")
        } catch {
            garage.errorMessage = "Création du PDF impossible : \(error.localizedDescription)"
        }
    }
}


private struct GarageInvoicesView: View {
    let moto: MotorcycleProfile
    @ObservedObject var garage: MaintenanceGarage
    @Environment(\.dismiss) private var dismiss
    @State private var category: InvoiceCategory = .purchase
    @State private var title = ""
    @State private var date = Date()
    @State private var importing = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var error: String?
    @State private var pendingDelete: GarageInvoice?
    @State private var confirmInvoiceDelete = false
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Ajouter une facture") {
                    Picker("Dossier", selection: $category) {
                        ForEach(InvoiceCategory.allCases) { item in Text(item.title).tag(item) }
                    }
                    TextField("Nom de la facture", text: $title)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Button { importing = true } label: { Label("Importer PDF ou photo", systemImage: "doc.badge.plus") }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choisir dans Photos", systemImage: "photo")
                    }
                }
                ForEach(InvoiceCategory.allCases) { item in
                    Section(item.title) {
                        let records = garage.invoices(for: moto.id, category: item)
                        if records.isEmpty { Text("Aucune facture").foregroundStyle(.secondary) }
                        ForEach(records) { invoice in
                            HStack {
                                Button { previewURL = garage.invoiceURL(invoice) } label: {
                                    VStack(alignment: .leading) {
                                        Text(invoice.title).font(.headline)
                                        Text(invoice.date.formatted(date: .numeric, time: .omitted)).font(.caption)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Spacer()
                                ShareLink(item: garage.invoiceURL(invoice)) { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityLabel("Ouvrir ou partager la facture")
                            }
                            .swipeActions { Button("Supprimer", role: .destructive) { pendingDelete = invoice; confirmInvoiceDelete = true } }
                        }
                    }
                }
            }
            .quickLookPreview($previewURL)
            .navigationTitle("Factures · \(moto.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                    guard (values.fileSize ?? 0) <= 25 * 1024 * 1024 else { error = "Document supérieur à 25 Mo."; return }
                    try save(data: Data(contentsOf: url), type: values.contentType ?? .data,
                             fallback: url.deletingPathExtension().lastPathComponent)
                } catch { self.error = error.localizedDescription }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                let selectedCategory = category
                let selectedDate = date
                let selectedTitle = title
                Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let photo = UIImage(data: data), let jpeg = photo.jpegData(compressionQuality: 0.9) else {
                            self.error = "Impossible de lire la photo."; selectedPhoto = nil; return
                        }
                        try garage.addInvoice(motorcycleID: moto.id, category: selectedCategory, date: selectedDate,
                                              title: selectedTitle.isEmpty ? "Facture photo" : selectedTitle, data: jpeg, type: .jpeg)
                        if title == selectedTitle { title = "" }
                    } catch { self.error = error.localizedDescription }
                    selectedPhoto = nil
                }
            }
            .confirmationDialog("Supprimer cette facture ?", isPresented: $confirmInvoiceDelete) {
                Button("Supprimer", role: .destructive) {
                    if let invoice = pendingDelete {
                        do { try garage.deleteInvoice(invoice) } catch { self.error = error.localizedDescription }
                    }
                    pendingDelete = nil
                }
            }
            .alert("Factures", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }.tint(GarageUI.accent).preferredColorScheme(.dark)
    }

    private func save(data: Data, type: UTType, fallback: String) throws {
        try garage.addInvoice(motorcycleID: moto.id, category: category, date: date,
                              title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : title,
                              data: data, type: type)
        title = ""
    }
}
