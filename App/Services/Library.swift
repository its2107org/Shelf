import Foundation
import SwiftData
import WidgetKit
import CoreSpotlight
import UniformTypeIdentifiers
import UIKit

/// Keeps the saved list up to date: brings in things shared from other apps, prepares their
/// text, and tells the widgets and Spotlight.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    @Published private(set) var isWorking = false
    private var processing = false

    private init() {
        let schema = Schema([Article.self])
        let config = ModelConfiguration("Shelf", schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A damaged store should never stop the app opening; start fresh in memory.
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
    }

    // MARK: Saving

    @discardableResult
    func save(url: URL, title: String? = nil, origin: Article.Origin = .saved) -> Article {
        if let existing = article(for: url) {
            if origin == .saved && existing.origin == .recommended {
                existing.origin = .saved
                existing.createdAt = .now
            }
            try? context.save()
            refreshOutside()
            return existing
        }
        let article = Article(url: url, title: title, origin: origin)
        context.insert(article)
        try? context.save()
        refreshOutside()
        return article
    }

    func article(for url: URL) -> Article? {
        let target = url.absoluteString
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.urlString == target })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func article(id: UUID) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func delete(_ article: Article) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [article.id.uuidString])
        context.delete(article)
        try? context.save()
        refreshOutside()
    }

    func setRead(_ article: Article, _ read: Bool) {
        article.readAt = read ? .now : nil
        if !read { article.progressIndex = 0 }
        try? context.save()
        refreshOutside()
    }

    func toggleFavorite(_ article: Article) {
        article.isFavorite.toggle()
        try? context.save()
    }

    // MARK: Bringing things in and preparing them

    /// Imports anything saved from the Share button, then prepares any article still waiting.
    func sync() async {
        importInbox()
        await processPending()
    }

    func importInbox() {
        let items = Inbox.items()
        guard !items.isEmpty else { return }
        for item in items {
            let url = item.url.flatMap(URL.init(string:))
            if article(id: item.id) == nil, url.map({ article(for: $0) == nil }) ?? true {
                let article = Article(id: item.id, url: url, title: item.title, createdAt: item.createdAt)
                if let extracted = item.extracted, extracted.hasReadableText, url.map({ extracted.isComplete(for: $0) }) ?? true {
                    article.apply(extracted)
                } else if let extracted = item.extracted, extracted.hasReadableText {
                    // Only a teaser came through the Share button; show it, but keep trying for the rest.
                    article.apply(extracted)
                    article.isPartial = true
                    article.status = .pending
                } else if url == nil, let text = item.sharedText {
                    // Plain text shared on its own becomes a note.
                    let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    article.apply(ExtractedArticle(title: item.title ?? String(text.prefix(80)), byline: nil, siteName: "Note", excerpt: nil, leadImage: nil, blocks: paragraphs.map { Block(t: .paragraph, text: $0) }))
                    article.status = .ready
                } else {
                    article.sharedText = item.sharedText
                }
                context.insert(article)
            }
            Inbox.remove(item.id)
        }
        try? context.save()
        refreshOutside()
    }

    func processPending() async {
        guard !processing else { return }
        processing = true
        isWorking = true
        defer { processing = false; isWorking = false }

        let pendingRaw = Article.Status.pending.rawValue
        let failedRaw = Article.Status.failed.rawValue
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { ($0.statusRaw == pendingRaw || $0.statusRaw == failedRaw) && $0.attempts < 3 },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let waiting = (try? context.fetch(descriptor)) ?? []
        for article in waiting {
            await prepare(article)
        }
    }

    func prepare(_ article: Article) async {
        guard let url = article.url else { return }
        article.attempts += 1
        do {
            let extracted = try await Extractor.shared.fetchAndExtract(url)
            article.apply(extracted)
            if article.status == .linkOnly, let text = article.sharedText, !text.isEmpty {
                article.blocksData = try? JSONEncoder().encode([Block(t: .paragraph, text: text)])
                article.blockCount = 1
            }
            ImageCache.shared.prefetch(([extracted.leadImage] + extracted.blocks.map(\.src)).compactMap { $0 }.prefix(12).compactMap(URL.init(string:)))
        } catch ExtractorError.notReadable {
            article.status = .linkOnly
        } catch {
            article.status = .failed
        }
        try? context.save()
        refreshOutside()
    }

    /// Stores the article text picked up from the page Ian opened inside Shelf, and remembers the
    /// site's login so future articles from it come through in full by themselves.
    func applyCaptured(_ extracted: ExtractedArticle, to article: Article, from url: URL) async {
        article.apply(extracted)
        article.isPartial = false
        article.status = .ready
        try? context.save()
        refreshOutside()
        ImageCache.shared.prefetch(([extracted.leadImage] + extracted.blocks.map(\.src)).compactMap { $0 }.prefix(12).compactMap(URL.init(string:)))
        if url.isPaywalledSite { SubscribedSites.add(url.shelfHostName) }
        await SignInWebView.shareCookies()
    }

    func retry(_ article: Article) async {
        article.attempts = 0
        article.status = .pending
        await prepare(article)
    }

    // MARK: Widgets and Spotlight

    func refreshOutside() {
        let savedRaw = Article.Origin.saved.rawValue
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.readAt == nil && $0.originRaw == savedRaw },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let unread = (try? context.fetch(descriptor)) ?? []
        descriptor.fetchLimit = 1
        let next = unread.first.map {
            WidgetSnapshot.Next(id: $0.id, title: $0.title, source: $0.sourceName, minutes: $0.minutes)
        }
        SnapshotStore.write(WidgetSnapshot(unreadCount: unread.count, next: next, updatedAt: .now))
        WidgetCenter.shared.reloadAllTimelines()
        index(unread)
    }

    private func index(_ articles: [Article]) {
        let items = articles.prefix(500).map { article -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = article.title
            attributes.contentDescription = [article.sourceName, article.excerpt].compactMap { $0 }.joined(separator: " · ")
            attributes.url = article.url
            return CSSearchableItem(uniqueIdentifier: article.id.uuidString, domainIdentifier: "articles", attributeSet: attributes)
        }
        CSSearchableIndex.default().indexSearchableItems(Array(items))
    }

    // MARK: Housekeeping

    /// Removes old recommendations Ian never saved.
    func pruneRecommendations() {
        let recRaw = Article.Origin.recommended.rawValue
        let cutoff = Date.now.addingTimeInterval(-21 * 24 * 3600)
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.originRaw == recRaw && $0.createdAt < cutoff })
        for article in (try? context.fetch(descriptor)) ?? [] {
            context.delete(article)
        }
        try? context.save()
    }
}
