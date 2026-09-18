import DyorKit
import SafariServices
import SwiftUI

/// Crypto headlines from the major outlets' public feeds, newest first, with a source filter. Articles open in an
/// in-app Safari view on the publisher's site. Opened from the side menu as a full-screen page.
struct NewsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model = NewsModel()
    @State private var source: String?
    @State private var article: NewsArticle?

    private var shown: [NewsArticle] {
        guard let source else { return model.articles }
        return model.articles.filter { $0.source == source }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.articles.isEmpty {
                    if model.loading {
                        ProgressView("Loading headlines…").controlSize(.large)
                    } else {
                        ContentUnavailableView("No Headlines", systemImage: "newspaper", description: Text(model.error ?? "The news feeds could not be reached. Pull to try again."))
                    }
                } else {
                    List {
                        Section {
                            ForEach(shown) { item in
                                Button { Haptics.tap(); article = item } label: { NewsRow(article: item) }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            }
                        } header: {
                            sourceChips
                                .textCase(nil)
                                .listRowInsets(EdgeInsets())
                        } footer: {
                            Text("Headlines come straight from each publisher's feed.").font(.caption)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("News")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }.accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let updated = model.updatedAt { Text(updated, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .refreshable { await model.load(env: env, force: true) }
            .task { await model.load(env: env, force: false) }
            .sheet(item: $article) { item in SafariView(url: item.link).ignoresSafeArea() }
        }
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: source == nil) { source = nil }
                ForEach(model.sources, id: \.self) { name in
                    chip(name, selected: source == name) { source = name }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? Color.brand : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct NewsRow: View {
    let article: NewsArticle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(article.source).font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                    if let published = article.published {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(published, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(article.title).font(.subheadline.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !article.summary.isEmpty {
                    Text(article.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let image = article.imageURL {
                AsyncImage(url: image) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color(.tertiarySystemFill) }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .contentShape(Rectangle())
    }
}

/// An in-app Safari page for a publisher's article.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.brand)
        return controller
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

@Observable
@MainActor
final class NewsModel {
    private(set) var articles: [NewsArticle] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?

    /// Sources present in the loaded headlines, in the service's order.
    var sources: [String] {
        let present = Set(articles.map(\.source))
        return NewsService.defaultSources.map(\.name).filter { present.contains($0) }
    }

    func load(env: AppEnvironment, force: Bool) async {
        loading = articles.isEmpty
        defer { loading = false }
        let latest = await env.news.latest(limit: 150, force: force)
        if latest.isEmpty {
            if articles.isEmpty { error = "The news feeds could not be reached. Check your connection and pull to refresh." }
        } else {
            articles = latest
            error = nil
            updatedAt = .now
        }
    }
}
