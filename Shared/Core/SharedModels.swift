import Foundation

/// One piece of an article's reading view.
struct Block: Codable, Hashable {
    enum Kind: String, Codable {
        case heading = "h"
        case paragraph = "p"
        case quote = "q"
        case listItem = "li"
        case image = "img"
        case preformatted = "pre"
    }

    var t: Kind
    var text: String?
    var src: String?
    var caption: String?
}

/// What the extractor produces from a web page or a post.
struct ExtractedArticle: Codable {
    var title: String?
    var byline: String?
    var siteName: String?
    var excerpt: String?
    var leadImage: String?
    var blocks: [Block]
    /// True when only the start of a subscriber-only article came through.
    var partial: Bool?

    var wordCount: Int {
        blocks.reduce(0) { total, block in
            total + (block.text?.split(whereSeparator: { $0 == " " || $0 == "\n" }).count ?? 0)
        }
    }

    /// True when there is enough text to be worth reading inside the app.
    var hasReadableText: Bool {
        blocks.filter { $0.t != .image }.count >= 2 || wordCount >= 60
    }

    /// Whether this looks like the whole article rather than a subscriber teaser. Only sites with
    /// paywalls are judged on length; everywhere else, any readable text counts.
    func isComplete(for url: URL) -> Bool {
        guard hasReadableText else { return false }
        return !url.isPaywalledSite || wordCount >= 350
    }
}

/// Something saved from the share sheet, waiting for the app to pick it up.
struct InboxItem: Codable, Identifiable {
    var id: UUID
    var url: String?
    var title: String?
    var sharedText: String?
    var createdAt: Date
    var extracted: ExtractedArticle?
}

/// The little bit of data the widgets show.
struct WidgetSnapshot: Codable {
    struct Next: Codable {
        var id: UUID
        var title: String
        var source: String
        var minutes: Int?
    }

    var unreadCount: Int
    var next: Next?
    var updatedAt: Date

    static let empty = WidgetSnapshot(unreadCount: 0, next: nil, updatedAt: .distantPast)
}

extension URL {
    /// A friendly source name such as "bbc.co.uk".
    var shelfHostName: String {
        var host = self.host ?? ""
        for prefix in ["www.", "m.", "mobile.", "amp."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host
    }

    /// Sites that show non-subscribers only the start of an article.
    static let paywalledHosts: [String] = [
        "nytimes.com", "ft.com", "wsj.com", "economist.com", "bloomberg.com", "theatlantic.com",
        "newyorker.com", "washingtonpost.com", "thetimes.com", "thetimes.co.uk", "telegraph.co.uk",
        "theinformation.com", "businessinsider.com", "barrons.com", "wired.com", "hbr.org",
        "nymag.com", "foreignaffairs.com", "thesundaytimes.co.uk", "spectator.co.uk", "newstatesman.com",
        "axios.com", "fortune.com", "forbes.com", "reuters.com", "puck.news", "theathletic.com"
    ]

    var isPaywalledSite: Bool {
        let host = shelfHostName
        let matches = { (site: String) in host == site || host.hasSuffix("." + site) }
        return URL.paywalledHosts.contains(where: matches) || SubscribedSites.all.contains(where: matches)
    }

    var isPost: Bool {
        let host = shelfHostName
        return (host == "x.com" || host == "twitter.com") && path.contains("/status/")
    }
}
