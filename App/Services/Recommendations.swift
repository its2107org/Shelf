import Foundation
import SwiftData

/// Fetches Claude's daily picks and adds them to the For You tab.
@MainActor
final class Recommendations: ObservableObject {
    static let shared = Recommendations()

    struct Feed: Decodable {
        struct Item: Decodable {
            var url: String
            var title: String
            var source: String?
            var summary: String?
            var why: String?
            var image: String?
            var minutes: Int?
        }
        var generatedAt: Date?
        var items: [Item]
    }

    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "ShelfFeedURL") as? String).flatMap(URL.init(string:))
    }

    func refresh(force: Bool = false) async {
        guard let feedURL, !isLoading, !Demo.isOn else { return }
        if !force, let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 30 * 60 { return }
        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { failed = true; return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let feed = try decoder.decode(Feed.self, from: data)
            apply(feed)
            lastUpdated = .now
            failed = false
        } catch {
            failed = true
        }
    }

    private var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "dismissedPicks") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: "dismissedPicks") }
    }

    /// "Not for me": hides a pick for good.
    func dismiss(_ article: Article) {
        if let url = article.urlString { dismissed.insert(url) }
        Library.shared.delete(article)
    }

    private func apply(_ feed: Feed) {
        let library = Library.shared
        let stamp = feed.generatedAt ?? .now
        for (offset, item) in feed.items.enumerated() {
            guard let url = URL(string: item.url), !dismissed.contains(item.url) else { continue }
            if let existing = library.article(for: url) {
                if existing.origin == .recommended {
                    existing.recommendationReason = item.why
                }
                continue
            }
            let article = Article(url: url, title: item.title, origin: .recommended, createdAt: stamp.addingTimeInterval(-Double(offset)))
            article.siteName = item.source ?? url.shelfHostName
            article.excerpt = item.summary
            article.leadImage = item.image
            article.recommendationReason = item.why
            article.recommendedAt = stamp
            if let minutes = item.minutes { article.wordCount = minutes * 230 }
            library.context.insert(article)
        }
        try? library.context.save()
        library.pruneRecommendations()
    }
}
