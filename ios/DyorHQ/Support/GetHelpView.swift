import SwiftUI
import UIKit

/// DyorHQ's brand line and the places to reach it: the site, the X profile and the support inbox.
enum SupportLinks {
    static let name = "DyorHQ"
    static let tagline = "The RWA HQ for social trading"
    static let site = URL(string: "https://dyorhq.fun")!
    static let helpCenter = URL(string: "https://dyorhq.fun/support")!
    static let terms = URL(string: "https://dyorhq.fun/terms")!
    static let supportEmail = "team@dyorhq.fun"
    static let xHandle = "@DyorHQ_"
    static let x: URL? = URL(string: "https://x.com/DyorHQ_")

    /// A mail link with the subject and the app / device details support asks for.
    static func mail(subject: String, body: String = "") -> URL? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let details = "\n\n—\nDyorHQ iOS \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body + details)]
        return components.url
    }
}

/// Get Help: how to reach support and where the community lives, in the grouped-rows shape of the reference app
/// (Help Center, Contact Support, Report a Bug; X). Opened from the side menu as a full-screen page.
struct GetHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { GetHelpContent().padding(16) }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                        .accessibilityLabel("Back")
                }
            }
        }
    }
}

/// The support rows themselves, so Profile can push them inside its own navigation.
struct GetHelpContent: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Get Help") {
                HelpRow(symbol: "envelope", title: "Contact Support", detail: SupportLinks.supportEmail) { mail(subject: "DyorHQ support") }
                HelpRow(symbol: "ladybug", title: "Report a Bug", detail: "Tell us what went wrong") { mail(subject: "DyorHQ bug report", body: "What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n") }
            }
            if let x = SupportLinks.x {
                group("Community") {
                    HelpRow(symbol: "at", title: "X", detail: SupportLinks.xHandle) { openURL(x) }
                }
            }
            group("About") {
                HelpRow(symbol: "globe", title: "dyorhq.fun", detail: SupportLinks.tagline) { openURL(SupportLinks.site) }
                HelpRow(symbol: "doc.text", title: "Terms of Use", detail: "dyorhq.fun/terms") { openURL(SupportLinks.terms) }
            }
            Text("Self-custodial: support can never reach your keys or funds. Never share a recovery phrase with anyone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            rows()
        }
    }

    private func mail(subject: String, body: String = "") {
        guard let url = SupportLinks.mail(subject: subject, body: body) else { return }
        openURL(url)
    }

}

/// One support row: a symbol on a tinted square, a title and a one-line description, a chevron.
private struct HelpRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 40, height: 40)
                    .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
    }
}
