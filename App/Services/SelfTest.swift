import Foundation

/// Automated check used by the build robot (launched with -ShelfSelfTest): fetches today's top
/// story from a few real news sites and a post on X, and records how the extraction went.
@MainActor
enum SelfTest {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-ShelfSelfTest") }

    private static let feeds = [
        "https://feeds.bbci.co.uk/news/rss.xml",
        "https://www.theguardian.com/uk/rss",
        "https://www.theverge.com/rss/index.xml",
        "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml",
        "https://feeds.npr.org/1001/rss.xml"
    ]
    private static let fixed = [
        "https://x.com/jack/status/20",
        "https://paulgraham.com/greatwork.html",
        "https://en.wikipedia.org/wiki/Bookcase"
    ]

    struct Result: Encodable {
        var url: String
        var ok: Bool
        var ms: Int
        var title: String?
        var site: String?
        var words: Int?
        var paragraphs: Int?
        var images: Int?
        var firstText: String?
        var error: String?
    }

    static func runIfRequested() {
        guard isOn else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for feed in feeds {
                if let url = await firstLink(in: feed) { urls.append(url) }
            }
            urls += fixed.compactMap(URL.init(string:))
            var results: [Result] = []
            for url in urls {
                let start = Date()
                do {
                    let article = try await Extractor.shared.fetchAndExtract(url)
                    results.append(Result(
                        url: url.absoluteString,
                        ok: article.hasReadableText,
                        ms: Int(Date().timeIntervalSince(start) * 1000),
                        title: article.title,
                        site: article.siteName,
                        words: article.wordCount,
                        paragraphs: article.blocks.filter { $0.t == .paragraph }.count,
                        images: article.blocks.filter { $0.t == .image }.count,
                        firstText: article.blocks.first(where: { $0.t == .paragraph })?.text.map { String($0.prefix(160)) }
                    ))
                } catch {
                    results.append(Result(url: url.absoluteString, ok: false, ms: Int(Date().timeIntervalSince(start) * 1000), error: String(describing: error)))
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? encoder.encode(results).write(to: folder.appendingPathComponent("selftest.json"))
        }
    }

    private static func firstLink(in feed: String) async -> URL? {
        guard let url = URL(string: feed),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        guard let item = xml.range(of: "<item") else { return nil }
        let rest = xml[item.upperBound...]
        guard let open = rest.range(of: "<link>"), let close = rest.range(of: "</link>", range: open.upperBound..<rest.endIndex) else { return nil }
        let link = rest[open.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: link)
    }
}
