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
        guard !isBotCheck else { return false }
        return (blocks.filter { $0.t != .image }.count >= 2 && wordCount >= 30) || wordCount >= 60
    }

    /// Wording sites show when you're only seeing a preview (not logged in, or still checking).
    static let teaserPhrases = [
        "you have a preview view of this article", "checking your access", "when we have confirmed access",
        "subscribe to continue reading", "subscribe to read", "this article is for subscribers",
        "this article is only available to subscribers", "already a subscriber", "create a free account to continue",
        "log in or create a free account", "you've reached your limit", "you have reached your limit",
        "free articles remaining", "to continue reading, subscribe", "become a subscriber to continue",
        "unlock this article", "subscribe for full access", "keep reading for just"
    ]

    var isPaywallTeaser: Bool {
        blocks.contains { block in
            guard let text = block.text?.lowercased(), text.count < 400 else { return false }
            return ExtractedArticle.teaserPhrases.contains(where: { text.contains($0) })
        }
    }

    /// Page furniture that slips into articles ("Advertisement", "Listen · 6 min", ...).
    static func isClutter(_ block: Block) -> Bool {
        guard block.t != .image, var text = block.text?.lowercased() else { return false }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·•|–—-")))
        if text.count < 400, ExtractedArticle.teaserPhrases.contains(where: { text.contains($0) }) { return true }
        guard text.count < 70 else { return false }
        if text.isEmpty { return true }
        let exact: Set<String> = [
            "advertisement", "skip advertisement", "supported by", "listen", "share full article", "read in app",
            "continue reading the main story", "continue reading", "story continues below advertisement",
            "article continues below", "article continues below this ad", "advertisement - scroll to continue",
            "related content", "site index", "share", "save", "gift this article", "listen to this article",
            "skip to content", "sign up", "subscribe", "log in", "read more", "more on this story"
        ]
        if exact.contains(text) { return true }
        // "6:39 min", "5 min read", "listen · 6:39 min"
        if text.range(of: #"^(listen\s*·?\s*)?\d+(:\d+)?\s*(min|mins|minutes)(\s*(read|listen))?$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// The same article with page clutter removed.
    func withoutClutter() -> ExtractedArticle {
        var copy = self
        copy.blocks = blocks.filter { !ExtractedArticle.isClutter($0) }
        return copy
    }

    /// A "checking you're human" page some sites show before the article, not the article itself.
    var isBotCheck: Bool {
        let lowered = (title ?? "").lowercased()
        let titles = ["just a moment", "attention required", "access denied", "are you a robot", "are you a human",
                      "security check", "verifying you are human", "please verify", "bot verification", "captcha"]
        if titles.contains(where: { lowered.contains($0) }) { return true }
        guard wordCount < 80 else { return false }
        let text = blocks.compactMap(\.text).joined(separator: " ").lowercased()
        let phrases = ["verify you are human", "enable javascript and cookies", "checking your browser",
                       "unusual activity", "press & hold", "press and hold", "not a robot"]
        return phrases.contains(where: { text.contains($0) })
    }

    /// Whether this looks like the whole article rather than a subscriber teaser. Only sites with
    /// paywalls are judged on length; everywhere else, any readable text counts.
    func isComplete(for url: URL) -> Bool {
        guard hasReadableText, !isPaywallTeaser else { return false }
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
