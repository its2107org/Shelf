import SwiftUI
import SwiftData

struct SavedView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case unread = "Unread"
        case read = "Read"
        case favourites = "Favourites"
        var id: String { rawValue }
    }

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var library: Library
    @Query(filter: #Predicate<Article> { $0.originRaw == 0 }, sort: \Article.createdAt, order: .reverse)
    private var articles: [Article]

    @State private var filter: Filter = .unread
    @State private var search = ""

    private var shown: [Article] {
        let base: [Article]
        switch filter {
        case .unread: base = articles.filter { !$0.isRead }
        case .read: base = articles.filter { $0.isRead }.sorted { ($0.readAt ?? .distantPast) > ($1.readAt ?? .distantPast) }
        case .favourites: base = articles.filter { $0.isFavorite }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.sourceName.localizedCaseInsensitiveContains(query)
        }
    }

    /// Unread and Favourites are grouped into topic sections; Read stays in reading order.
    private var sectioned: Bool { filter != .read && search.trimmingCharacters(in: .whitespaces).isEmpty && shown.count >= 4 }

    private struct TopicSection: Identifiable {
        let topic: Topic
        let items: [Article]
        var id: Topic { topic }
    }

    private var sections: [TopicSection] {
        let groups = Dictionary(grouping: shown) { Topic.of($0) }
        return Topic.allCases.compactMap { topic in groups[topic].map { TopicSection(topic: topic, items: $0) } }
    }

    @ViewBuilder
    private func row(_ article: Article) -> some View {
        NavigationLink(value: article.id) {
            ArticleRow(article: article)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation { library.delete(article) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation { library.setRead(article, !article.isRead) }
            } label: {
                article.isRead
                    ? Label("Unread", systemImage: "circle")
                    : Label("Read", systemImage: "checkmark.circle")
            }
            .tint(.blue)
            Button {
                library.toggleFavorite(article)
            } label: {
                Label(article.isFavorite ? "Unfavourite" : "Favourite", systemImage: article.isFavorite ? "star.slash" : "star")
            }
            .tint(.orange)
        }
        .contextMenu {
            if let url = article.url {
                ShareLink(item: url)
                Button { OriginalOpener.open(url) } label: { Label("Open in App", systemImage: "arrow.up.forward.app") }
            }
            Button { library.toggleFavorite(article) } label: {
                Label(article.isFavorite ? "Unfavourite" : "Favourite", systemImage: "star")
            }
            Button(role: .destructive) { library.delete(article) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var unreadCount: Int { articles.filter { !$0.isRead }.count }

    var body: some View {
        NavigationStack(path: $router.savedPath) {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                }

                if sectioned {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { article in row(article) }
                        } header: {
                            Text(section.topic.rawValue)
                        }
                    }
                } else {
                    ForEach(shown) { article in row(article) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty {
                    emptyState
                }
            }
            .navigationTitle("Shelf")
            .searchable(text: $search, prompt: "Search")
            .refreshable { await library.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { router.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PasteButton(payloadType: URL.self) { urls in
                        guard let url = urls.first else { return }
                        Task { @MainActor in
                            let article = library.save(url: url)
                            await library.prepare(article)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .tint(.blue)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ReaderContainer(id: id)
            }
            .sheet(isPresented: $router.showSettings) { SettingsView() }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch filter {
            case .unread:
                ContentUnavailableView {
                    Label(articles.isEmpty ? "Nothing saved yet" : "All caught up", systemImage: articles.isEmpty ? "books.vertical" : "checkmark.circle")
                } description: {
                    Text(articles.isEmpty
                         ? "In any app, tap the Share button, then Shelf. It'll appear here, ready to read."
                         : "You've read everything you saved.")
                }
            case .read:
                ContentUnavailableView("Nothing read yet", systemImage: "book", description: Text("Articles you finish will appear here."))
            case .favourites:
                ContentUnavailableView("No favourites", systemImage: "star", description: Text("Swipe right on an article to make it a favourite."))
            }
        }
    }
}

struct ArticleRow: View {
    let article: Article
    var showReason = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.sourceName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(article.isRead && !showReason ? .secondary : .primary)
                    .lineLimit(3)
                if showReason, let reason = article.recommendationReason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if article.status == .pending && !showReason {
                        ProgressView().controlSize(.mini)
                    }
                    Text(showReason ? (article.minutes.map { "\($0) min read" } ?? "Article") : article.metaLine)
                    if article.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.orange).imageScale(.small)
                    }
                    if article.progress > 0.02 && !article.isRead {
                        ProgressView(value: article.progress)
                            .frame(width: 36)
                            .tint(.blue)
                    }
                    if showReason {
                        Spacer(minLength: 8)
                        ThumbButtons(article: article)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Thumbnail(article: article)
        }
        .contentShape(Rectangle())
    }
}

/// 👍 / 👎 on a For You pick. Thumbs down hides it; both teach the daily picks.
struct ThumbButtons: View {
    let article: Article

    var body: some View {
        HStack(spacing: 18) {
            Button {
                withAnimation { Recommendations.shared.rate(article, liked: true) }
            } label: {
                Image(systemName: article.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(article.rating == 1 ? Color.blue : Color.secondary)
            }
            .accessibilityLabel(article.rating == 1 ? "Liked" : "Like")
            Button {
                let id = article.id
                // Leave the article first if it's open, since thumbs down removes it.
                Router.shared.forYouPath.removeAll { $0 == id }
                withAnimation { Recommendations.shared.rate(article, liked: false) }
            } label: {
                Image(systemName: "hand.thumbsdown").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Not for me")
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .sensoryFeedback(.selection, trigger: article.rating)
    }
}

struct Thumbnail: View {
    let article: Article

    var body: some View {
        CachedImage(url: article.leadImage.flatMap(URL.init(string:)), maxPixel: 240) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.gradient)
                Text(String(article.sourceName.prefix(1)).uppercased())
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tint: Color {
        let palette: [Color] = [.blue, .indigo, .teal, .gray, .cyan, .mint]
        let sum = article.sourceName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
