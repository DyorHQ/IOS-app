import DyorKit
import SwiftUI

/// The home header, in the reference layout: the three-line menu button, a search field, and the profile avatar
/// on the right — the profile is one tap away from the top of the screen instead of a tab.
struct HomeHeader: View {
    @Binding var showSearch: Bool
    let error: String?
    let updatedAt: Date?
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social

    var body: some View {
        HStack(spacing: 10) {
            Button { Haptics.tap(); router.menuOpen = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .accessibilityLabel("Menu")

            Button { Haptics.tap(); showSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search tokens…").foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if let error {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.attention).accessibilityLabel(error)
                    } else if let updatedAt {
                        Text(updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.body)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search tokens")

            Button { Haptics.tap(); router.presented = .notifications } label: {
                Image(systemName: NotificationHub.shared.unreadCount > 0 ? "bell.badge" : "bell")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.brand, Color.primary)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        let unread = NotificationHub.shared.unreadCount
                        if unread > 0 {
                            Text(verbatim: unread > 99 ? "99+" : "\(unread)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.negative, in: Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            .accessibilityLabel("Notifications, \(NotificationHub.shared.unreadCount) unread")

            Button { Haptics.tap(); router.presented = .profile } label: {
                if let account = session.account, account.method == .watchOnly {
                    ZStack {
                        Circle().fill(Color(.secondarySystemGroupedBackground)).frame(width: 44, height: 44)
                        Image(systemName: "eye").foregroundStyle(.secondary)
                    }
                } else {
                    Avatar(url: avatarURL, initials: initials, size: 44)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? session.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
}
