import Foundation

/// Sorts saved articles into simple sections on the phone, from their title, site and summary.
enum Topic: String, CaseIterable, Identifiable {
    case consumer = "Consumer & Retail"
    case ai = "AI & Tech"
    case venture = "Venture & Deals"
    case markets = "Business & Markets"
    case longReads = "Long Reads"
    case posts = "Posts"
    case other = "Everything Else"

    var id: String { rawValue }

    private static let keywords: [(Topic, [String])] = [
        (.consumer, ["consumer", "retail", "restaurant", "brand", "food", "drink", "beverage", "snack", "beauty", "cosmetic",
                     "skincare", "pet", "grocery", "supermarket", "franchise", "chain", "store", "shopper", "fmcg", "cpg",
                     "fast-casual", "coffee", "starbucks", "chipotle", "cava", "mcdonald", "walmart", "target", "costco",
                     "tesco", "nike", "salon", "fitness", "gym", "wellness", "apparel", "fashion", "e-commerce", "ecommerce"]),
        (.ai, ["ai ", " ai", "a.i.", "artificial intelligence", "openai", "anthropic", "claude", "chatgpt", "gemini", "llm",
               "model", "nvidia", "chip", "robot", "agent", "software", "apple", "google", "microsoft", "meta ", "amazon",
               "tech", "startup", "data centre", "data center", "compute"]),
        (.venture, ["venture", "vc ", "funding", "raises", "raised", "series a", "series b", "valuation", "unicorn",
                    "decacorn", "private equity", "buyout", "acquire", "acquisition", "takeover", "merger", "deal", "ipo",
                    "investor", "fund "]),
        (.markets, ["economy", "economic", "inflation", "rates", "fed ", "bank of england", "markets", "stocks", "shares",
                    "bond", "earnings", "revenue", "profit", "tariff", "trade", "gdp", "jobs", "ceo", "company", "business"])
    ]

    static func of(_ article: Article) -> Topic {
        if article.url?.isPost == true { return .posts }
        if let minutes = article.minutes, minutes >= 25 { return .longReads }
        let text = " " + [article.title, article.sourceName, article.excerpt ?? ""].joined(separator: " ").lowercased() + " "
        var best: (Topic, Int)?
        for (topic, words) in keywords {
            let hits = words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            if hits > 0, hits > (best?.1 ?? 0) { best = (topic, hits) }
        }
        if let best { return best.0 }
        if let minutes = article.minutes, minutes >= 15 { return .longReads }
        return .other
    }
}

/// Ian's own sections, on top of the automatic ones.
@MainActor
enum MyTopics {
    private static let key = "myTopics"

    static var all: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Every section name, his own first.
    static var everything: [String] { all + Topic.allCases.map(\.rawValue).filter { !all.contains($0) } }

    static func name(for article: Article) -> String {
        if let custom = article.customTopic, !custom.isEmpty { return custom }
        return Topic.of(article).rawValue
    }

    static func add(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if !everything.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { all.append(name) }
        return everything.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func rename(_ old: String, to new: String, in articles: [Article]) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, old != new else { return }
        if let index = all.firstIndex(of: old) { all[index] = new } else { all.append(new) }
        // Renaming an automatic section turns it into one of his, keeping the same articles.
        for article in articles where name(for: article) == old { article.customTopic = new }
        try? Library.shared.context.save()
    }

    static func remove(_ topic: String, in articles: [Article]) {
        all.removeAll { $0 == topic }
        for article in articles where article.customTopic == topic { article.customTopic = nil }
        try? Library.shared.context.save()
    }
}
