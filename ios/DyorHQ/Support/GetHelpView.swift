import DyorKit
import SwiftUI
import UIKit

/// DyorHQ's brand line and the places to reach it: the site, the Help Center (the docs), the X profile and the support
/// inbox.
enum SupportLinks {
    static let name = "DyorHQ"
    static let tagline = "The RWA HQ for social trading"
    static let site = URL(string: "https://dyorhq.fun")!
    /// The docs home (dyorhq.gitbook.io/docs).
    static let helpCenter = DocsLinks.home.url
    static let terms = URL(string: "https://dyorhq.fun/terms")!
    static let privacy = URL(string: "https://dyorhq.fun/privacy")!
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

/// Get Help: the docs to learn from, how to reach support and where the community lives, in the grouped-rows shape of
/// the reference app (Help Center, Getting Started, Risk Disclosures, Contracts & Addresses; Contact Support, Report a
/// Bug; X). Opened from the side menu as a full-screen page.
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
            // The docs, opened in Safari like the Terms and Privacy links.
            group("Learn") {
                HelpRow(symbol: "book", title: "Help Center", detail: "Guides to every part of DyorHQ") { openURL(SupportLinks.helpCenter) }
                HelpRow(symbol: "flag", title: "Getting Started", detail: "From sign-in to your first trade") { openURL(DocsLinks.quickstart.url) }
                HelpRow(symbol: "exclamationmark.triangle", title: "Risk Disclosures", detail: "Read these before you trade") { openURL(DocsLinks.riskDisclosures.url) }
                HelpRow(symbol: "checkmark.seal", title: "Contracts & Addresses", detail: "Verify every contract DyorHQ uses") { openURL(DocsLinks.contractsAndAddresses.url) }
            }
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
                HelpRow(symbol: "hand.raised", title: "Privacy Policy", detail: "dyorhq.fun/privacy") { openURL(SupportLinks.privacy) }
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
