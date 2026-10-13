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
    private var inFlight = Set<UUID>()

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
                Feedback.shared.record(.save, existing)
            }
            try? context.save()
            refreshOutside()
            return existing
        }
        let article = Article(url: url, title: title, origin: origin)
        context.insert(article)
        try? context.save()
        refreshOutside()
        if origin == .saved { Feedback.shared.record(.save, article) }
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
        noteDone(article)
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
        recheckSaved()
        importInbox()
        await processPending()
        await Feedback.shared.send()
        Feedback.shared.queueChanged()
    }

    /// Tidies articles saved by older versions: strips page clutter and spots subscriber previews
    /// that were saved as if complete, so they offer to load the full article.
    func recheckSaved() {
        let key = "recheckedSavedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let readyRaw = Article.Status.ready.rawValue
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.statusRaw == readyRaw })
        for article in (try? context.fetch(descriptor)) ?? [] {
            let blocks = article.blocks
            let probe = ExtractedArticle(title: nil, byline: nil, siteName: nil, excerpt: nil, leadImage: nil, blocks: blocks)
            if probe.isPaywallTeaser { article.isPartial = true }
            let cleaned = blocks.filter { !ExtractedArticle.isClutter($0) }
            if cleaned.count != blocks.count {
                article.blocksData = try? JSONEncoder().encode(cleaned)
                article.blockCount = cleaned.count
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
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
                if url != nil { Feedback.shared.record(.save, article) }
            } else if let url, let existing = article(for: url), existing.id != item.id {
                // Shared again: bring it to the top, and if it never came through in full, try again
                // (Ian may have logged in since).
                existing.createdAt = item.createdAt
                existing.readAt = nil
                if existing.origin == .recommended { existing.origin = .saved }
                if let extracted = item.extracted, extracted.isComplete(for: url), extracted.wordCount > existing.wordCount {
                    existing.apply(extracted)
                } else if existing.status != .ready || existing.isPartial {
                    existing.attempts = 0
                    existing.status = .pending
                }
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
        for article in waiting where article.modelContext != nil && (article.status == .pending || article.status == .failed) {
            await prepare(article)
        }
    }

    func prepare(_ article: Article) async {
        guard let url = article.url, inFlight.insert(article.id).inserted else { return }
        defer { inFlight.remove(article.id) }
        article.attempts += 1
        do {
            let extracted = try await Extractor.shared.fetchAndExtract(url)
            guard article.modelContext != nil else { return }
            // Picked up in full from the page meanwhile: keep that.
            if article.status == .ready && !article.isPartial { return }
            // Already holding more text (say, from Safari) than this fetch got: keep it.
            if article.blockCount > 0 && extracted.wordCount < article.wordCount {
                article.status = .ready
                try? context.save()
                refreshOutside()
                return
            }
            article.apply(extracted)
            if article.status == .linkOnly, let text = article.sharedText, !text.isEmpty {
                article.blocksData = try? JSONEncoder().encode([Block(t: .paragraph, text: text)])
                article.blockCount = 1
            }
            ImageCache.shared.prefetch(([extracted.leadImage] + extracted.blocks.map(\.src)).compactMap { $0 }.prefix(12).compactMap(URL.init(string:)))
        } catch ExtractorError.notReadable where article.blockCount == 0 && !url.isPaywalledSite {
            article.status = .linkOnly
        } catch {
            guard article.modelContext != nil, !(article.status == .ready && !article.isPartial) else { return }
            // Keep a teaser readable rather than hiding it behind an error.
            article.status = article.blockCount > 0 ? .ready : .failed
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
        if article.blockCount == 0 { article.status = .pending }
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
        Feedback.shared.queueChanged()
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

    // MARK: Reading queue for Lamplight

    private static let doneKey = "queueDone"
    private static let doneWindow: TimeInterval = 60 * 24 * 3600

    /// Remembers links Ian finished with whose article is about to go (deleted, turned down, or a
    /// read pick being tidied away), since nothing is left to look at afterwards.
    private func noteDone(_ article: Article, at date: Date = .now) {
        guard let url = article.urlString else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.doneWindow)
        var done = (UserDefaults.standard.dictionary(forKey: Self.doneKey) as? [String: Date] ?? [:]).filter { $0.value > cutoff }
        done[url] = max(done[url] ?? date, date)
        UserDefaults.standard.set(done, forKey: Self.doneKey)
    }

    /// Ian's unread saves, newest first, and every link he read, deleted or turned down lately.
    func readingQueue() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let cutoff = Date.now.addingTimeInterval(-Self.doneWindow)
        let savedRaw = Article.Origin.saved.rawValue
        let unreadDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.readAt == nil && $0.originRaw == savedRaw },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let saved = ((try? context.fetch(unreadDescriptor)) ?? []).filter { $0.urlString != nil }
        let savedURLs = Set(saved.compactMap(\.urlString))

        var done = (UserDefaults.standard.dictionary(forKey: Self.doneKey) as? [String: Date]) ?? [:]
        let readDescriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.readAt != nil })
        for article in (try? context.fetch(readDescriptor)) ?? [] {
            guard let url = article.urlString, let readAt = article.readAt else { continue }
            done[url] = max(done[url] ?? readAt, readAt)
        }
        // Something saved again since is back on the list, not done.
        let doneURLs = done
            .filter { $0.value > cutoff && !savedURLs.contains($0.key) }
            .sorted { $0.value > $1.value }
            .map(\.key)

        let items = saved.map { article -> [String: Any] in
            [
                "url": article.urlString ?? "",
                "title": article.title,
                "site": article.sourceName,
                "savedAt": iso.string(from: article.createdAt),
                "minutes": article.minutes.map { $0 as Any } ?? NSNull(),
            ]
        }
        return ["saved": items, "done": doneURLs]
    }

    // MARK: Housekeeping

    /// Removes old recommendations Ian never saved.
    func pruneRecommendations() {
        let recRaw = Article.Origin.recommended.rawValue
        let cutoff = Date.now.addingTimeInterval(-21 * 24 * 3600)
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.originRaw == recRaw && $0.createdAt < cutoff })
        for article in (try? context.fetch(descriptor)) ?? [] {
            if let readAt = article.readAt { noteDone(article, at: readAt) }
            context.delete(article)
        }
        try? context.save()
    }
}
