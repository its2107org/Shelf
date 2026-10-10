import Foundation
import SwiftData

/// Sample content used only for automated screenshots (launched with -ShelfDemo). Never shown otherwise.
@MainActor
enum Demo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-ShelfDemo") }

    static func seedIfRequested() {
        guard isOn else { return }
        let library = Library.shared
        let context = library.context
        try? context.delete(model: Article.self)

        let paragraph = "This is sample text standing in for a real article, so the reading screen can be checked. Real articles you save appear here as clean, plain text, in a calm book-style font, with their pictures and none of the clutter."
        let samples: [(String, String, String, Int)] = [
            ("Example: how a challenger snack brand won shelf space", "Sample News", "https://example.com/a", 9),
            ("Example: what the latest AI models mean for business", "Sample Weekly", "https://example.com/b", 14),
            ("Example: a restaurant chain's plan for 500 new sites", "Sample Journal", "https://example.com/c", 6),
            ("Example: the long read on a venture fund's best bet", "Sample Magazine", "https://example.com/d", 22)
        ]
        for (offset, sample) in samples.enumerated() {
            let article = Article(url: URL(string: sample.2), title: sample.0, createdAt: Date.now.addingTimeInterval(-Double(offset) * 3600))
            var blocks = [Block(t: .paragraph, text: paragraph)]
            blocks.append(Block(t: .heading, text: "A sample heading"))
            blocks.append(contentsOf: Array(repeating: Block(t: .paragraph, text: paragraph), count: 5))
            blocks.insert(Block(t: .quote, text: "A sample quote, shown the way quotes appear in articles."), at: 2)
            article.apply(ExtractedArticle(title: sample.0, byline: "By a sample writer", siteName: sample.1, excerpt: paragraph, leadImage: nil, blocks: blocks))
            article.wordCount = sample.3 * 230
            if offset == 1 { article.progressIndex = 3 }
            if offset == 2 { article.isFavorite = true }
            context.insert(article)
        }
        let picks: [(String, String, String)] = [
            ("Example pick: the economics of next-generation consumer brands", "Sample Review", "Fits your interest in consumer investing and challenger brands."),
            ("Example pick: inside a long investigation into AI and belief", "Sample Times", "A long-form piece on AI, like the ones you asked for.")
        ]
        for (offset, pick) in picks.enumerated() {
            let article = Article(url: URL(string: "https://example.com/pick\(offset)"), title: pick.0, origin: .recommended)
            article.siteName = pick.1
            article.recommendationReason = pick.2
            article.recommendedAt = .now
            article.apply(ExtractedArticle(title: pick.0, byline: nil, siteName: pick.1, excerpt: nil, leadImage: nil, blocks: Array(repeating: Block(t: .paragraph, text: paragraph), count: 4)))
            article.wordCount = (offset == 0 ? 8 : 25) * 230
            context.insert(article)
        }
        try? context.save()
        library.refreshOutside()

        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ShelfDemoForYou") {
            Router.shared.tab = .forYou
        }
        if args.contains("-ShelfDemoReader") {
            let descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            if let first = try? context.fetch(descriptor).first(where: { $0.origin == .saved }) {
                if args.contains("-ShelfDemoPartial") { first.isPartial = true }
                Router.shared.savedPath = [first.id]
            }
        }
    }
}
