import Foundation
import SwiftData

@Model
final class Article {
    enum Status: Int, Codable {
        case pending = 0
        case ready = 1
        case failed = 2
        /// Saved, but there's no article text to show (a video, a shop page...). Opens the original.
        case linkOnly = 3
    }

    enum Origin: Int, Codable {
        case saved = 0
        case recommended = 1
    }

    @Attribute(.unique) var id: UUID
    var urlString: String?
    var title: String
    var siteName: String?
    var byline: String?
    var excerpt: String?
    var leadImage: String?
    @Attribute(.externalStorage) var blocksData: Data?
    var wordCount: Int
    var statusRaw: Int
    var originRaw: Int
    var createdAt: Date
    var readAt: Date?
    var isFavorite: Bool
    /// Index of the furthest block reached, used to reopen where Ian left off.
    var progressIndex: Int
    var blockCount: Int
    var attempts: Int
    var recommendationReason: String?
    var recommendedAt: Date?
    var sharedText: String?
    /// Only the start of a subscriber-only article came through.
    var isPartial: Bool = false
    /// Ian's thumb on a For You pick: 1 liked, -1 not for him, 0 not rated.
    var rating: Int = 0

    init(id: UUID = UUID(), url: URL?, title: String? = nil, origin: Origin = .saved, createdAt: Date = .now) {
        self.id = id
        self.urlString = url?.absoluteString
        self.title = title ?? url?.shelfHostName ?? "Untitled"
        self.siteName = url?.shelfHostName
        self.wordCount = 0
        self.statusRaw = Status.pending.rawValue
        self.originRaw = origin.rawValue
        self.createdAt = createdAt
        self.isFavorite = false
        self.progressIndex = 0
        self.blockCount = 0
        self.attempts = 0
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var origin: Origin {
        get { Origin(rawValue: originRaw) ?? .saved }
        set { originRaw = newValue.rawValue }
    }

    var url: URL? { urlString.flatMap(URL.init(string:)) }

    var isRead: Bool { readAt != nil }

    var minutes: Int? {
        guard wordCount > 0 else { return nil }
        return max(1, Int((Double(wordCount) / 230).rounded()))
    }

    var sourceName: String {
        if let siteName, !siteName.isEmpty { return siteName }
        return url?.shelfHostName ?? "Note"
    }

    var metaLine: String {
        switch status {
        case .pending: return "Getting it ready…"
        case .failed: return "Couldn't get the text · tap to open"
        case .linkOnly: return url?.isPost == true ? "Post" : "Link"
        case .ready:
            if url?.isPost == true { return "Post" }
            if let minutes { return "\(minutes) min read" }
            return "Article"
        }
    }

    var blocks: [Block] {
        guard let blocksData else { return [] }
        return (try? JSONDecoder().decode([Block].self, from: blocksData)) ?? []
    }

    var progress: Double {
        guard blockCount > 1 else { return isRead ? 1 : 0 }
        return min(1, Double(progressIndex) / Double(blockCount - 1))
    }

    func apply(_ extracted: ExtractedArticle) {
        let teaser = extracted.isPaywallTeaser
        let extracted = extracted.withoutClutter()
        if let t = extracted.title, !t.isEmpty { title = t }
        if let s = extracted.siteName, !s.isEmpty { siteName = s }
        byline = extracted.byline
        excerpt = extracted.excerpt
        leadImage = extracted.leadImage
        blocksData = try? JSONEncoder().encode(extracted.blocks)
        blockCount = extracted.blocks.count
        wordCount = extracted.wordCount
        isPartial = (extracted.partial ?? false) || teaser
        status = extracted.hasReadableText ? .ready : .linkOnly
    }

    /// Plain text for reading aloud.
    var speechText: String {
        let body = blocks.compactMap { block -> String? in
            block.t == .image ? nil : block.text
        }
        return ([title] + body).joined(separator: "\n\n")
    }
}
