import SwiftUI
import MapKit

struct DestinationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var error: String?
    @State private var search: MKLocalSearch?
    @State private var requestID = UUID()
    let userRegion: MKCoordinateRegion?
    let onSelectDestination: (MKMapItem) -> Void

    var body: some View {
        RideSheet("Rechercher dans Rivroute") {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(RideTheme.muted)
                TextField("Destination ou adresse…", text: $query)
                    .submitLabel(.search).onSubmit { performSearch() }.accessibilityIdentifier("search.query")
                if !query.isEmpty {
                    Button { query = ""; results = []; error = nil; cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Effacer la recherche")
                }
            }.padding(16).background(RivetCockpit.panel, in: RoundedRectangle(cornerRadius: 16))
            Button("Rechercher", systemImage: "magnifyingglass") { performSearch() }
                .buttonStyle(RideButtonStyle()).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if searching { ProgressView("Recherche en cours…") }
            if let error { Text(error).foregroundStyle(RideTheme.orange) }
            ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                Button {
                    onSelectDestination(item); dismiss()
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(RivetCockpit.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name ?? "Destination").font(.headline)
                            if let address = item.address?.shortAddress { Text(address).font(.caption).foregroundStyle(RideTheme.muted) }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.foregroundStyle(RideTheme.ink).padding(18)
                        .background(RivetCockpit.panel, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
            }
            if !searching && results.isEmpty && error == nil {
                RideCard {
                    Label("Où veux-tu aller ?", systemImage: "map").font(.headline)
                    Text("Entre une ville, une adresse ou un lieu. Le calcul de l’itinéraire utilise ta position GPS et nécessite Internet.")
                        .font(.subheadline).foregroundStyle(RideTheme.muted)
                }
            }
        }.onDisappear { cancel() }
    }
    private func cancel() { requestID = UUID(); search?.cancel(); search = nil; searching = false }
    private func performSearch() {
        cancel()
        let token = requestID
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userRegion { request.region = userRegion }
        let task = MKLocalSearch(request: request)
        search = task; searching = true; error = nil; results = []
        task.start { response, failure in
            DispatchQueue.main.async {
                guard requestID == token else { return }
                search = nil; searching = false
                if let failure { error = failure.localizedDescription; return }
                results = response?.mapItems ?? []
                if results.isEmpty { error = "Aucun résultat. Essaie une adresse ou une ville plus précise." }
            }
        }
    }
}
