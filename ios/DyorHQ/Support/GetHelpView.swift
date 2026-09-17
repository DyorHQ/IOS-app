import SwiftUI
import UIKit

/// Where DyorHQ's support and community links live. The official site is dyorhq.fun; the X profile is set here
/// once the owner publishes the handle (until then the row says so and offers the site).
enum SupportLinks {
    static let site = URL(string: "https://dyorhq.fun")!
    static let helpCenter = URL(string: "https://dyorhq.fun/support")!
    static let terms = URL(string: "https://dyorhq.fun/terms")!
    static let supportEmail = "support@dyorhq.fun"
    /// The DyorHQ profile on X: replace with the real profile URL when it exists.
    static let x: URL? = nil

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
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Get Help") {
                        HelpRow(symbol: "questionmark.circle", title: "Help Center", detail: "Browse articles and FAQs") { openURL(SupportLinks.helpCenter) }
                        HelpRow(symbol: "envelope", title: "Contact Support", detail: "Email our support team") { mail(subject: "DyorHQ support") }
                        HelpRow(symbol: "ladybug", title: "Report a Bug", detail: "Help us improve the app") { mail(subject: "DyorHQ bug report", body: "What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n") }
                    }
                    if let x = SupportLinks.x {
                        group("Community") {
                            HelpRow(symbol: "at", title: "X", detail: "Follow us for updates") { openURL(x) }
                        }
                    }
                    group("About") {
                        HelpRow(symbol: "globe", title: "dyorhq.fun", detail: "The official site") { openURL(SupportLinks.site) }
                        HelpRow(symbol: "doc.text", title: "Terms of Use", detail: "How DyorHQ works, in writing") { openURL(SupportLinks.terms) }
                    }
                    Text("DyorHQ is self-custodial: support can never access your keys or move your funds. Never share a recovery phrase or private key with anyone, including people claiming to be DyorHQ support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
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
