import SwiftUI

enum RideTheme {
    static let background = RivetCockpit.asphalt
    static let ink = RivetCockpit.paper
    static let orange = RivetCockpit.orange
    static let muted = RivetCockpit.secondary
    static let line = RivetCockpit.line
}

struct RideCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RivetCockpit.panel)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(RideTheme.line, lineWidth: 1))
    }
}

struct RideButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.rideMapProfile) private var mapProfile

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(primary ? RivetCockpit.asphalt : RivetCockpit.paper)
            .background(primary ? (mapProfile?.menuAccent ?? RivetCockpit.lime)
                                : (mapProfile?.menuSecondary ?? RivetCockpit.raised))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
    }
}

struct RideSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rideMapProfile) private var mapProfile
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RideTheme.background)
            .foregroundStyle(RideTheme.ink)
            .navigationTitle(Text(LocalizedStringKey(title)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }.fontWeight(.semibold)
                }
            }
            .toolbarBackground(mapProfile?.menuSurface ?? RideTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(mapProfile?.menuAccent ?? RivetCockpit.lime)
        .preferredColorScheme(.dark)
        .presentationBackground(RivetCockpit.asphalt)
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255, opacity: 1)
    }
}
