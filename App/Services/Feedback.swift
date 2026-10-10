import Foundation

/// What Ian likes: his thumbs on For You picks and the things he saves. Kept on the phone, and,
/// once he connects his private GitHub project, sent there so the daily picker can learn from it.
/// Only titles, links and site names ever leave the phone: never article text or logins.
@MainActor
final class Feedback: ObservableObject {
    static let shared = Feedback()

    /// The private GitHub project the daily picker reads.
    static let repository = "its2107org/shelf-feedback"
    private static let path = "feedback.json"
    private static let vault = "shelf.feedback"

    struct Event: Codable, Equatable {
        enum Kind: String, Codable { case like, dislike, save }
        var kind: Kind
        var url: String
        var title: String
        var site: String
        var at: Date
    }

    @Published private(set) var isConnected: Bool
    @Published private(set) var lastSent: Date?

    private var events: [Event]
    private var sending = false
    private var dirty = false

    private init() {
        let stored = UserDefaults.standard.data(forKey: "feedbackEvents")
        events = stored.flatMap { try? JSONDecoder.iso.decode([Event].self, from: $0) } ?? []
        isConnected = SharedVault.read(service: Feedback.vault, account: "key") != nil
        lastSent = UserDefaults.standard.object(forKey: "feedbackSent") as? Date
    }

    // MARK: Recording

    func record(_ kind: Event.Kind, _ article: Article) {
        guard let url = article.urlString, !Demo.isOn, !SelfTest.isOn else { return }
        // A newer thumb on the same article replaces the older one.
        if kind != .save { events.removeAll { $0.url == url && $0.kind != .save } }
        else if events.contains(where: { $0.url == url && $0.kind == .save }) { return }
        events.append(Event(kind: kind, url: url, title: article.title, site: article.sourceName, at: .now))
        events = Array(events.suffix(400))
        persist()
        Task { await send() }
    }

    func clearRating(_ article: Article) {
        guard let url = article.urlString else { return }
        events.removeAll { $0.url == url && $0.kind != .save }
        persist()
        Task { await send() }
    }

    private func persist() {
        dirty = true
        if let data = try? JSONEncoder.iso.encode(events) {
            UserDefaults.standard.set(data, forKey: "feedbackEvents")
        }
    }

    // MARK: Connecting

    /// Checks the key works with the private project, then keeps it in the phone's Keychain.
    func connect(key: String) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, var request = Self.request("", key: key) else { return false }
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        _ = SharedVault.write(Data(key.utf8), service: Self.vault, account: "key")
        isConnected = true
        dirty = true
        await send()
        return true
    }

    func disconnect() {
        SharedVault.delete(service: Self.vault, account: "key")
        isConnected = false
    }

    // MARK: Sending

    /// Writes the whole list to the private project (it's small), replacing the old copy.
    func send() async {
        guard dirty || lastSent == nil, !sending,
              let keyData = SharedVault.read(service: Self.vault, account: "key") else { return }
        let key = String(decoding: keyData, as: UTF8.self)
        sending = true
        defer { sending = false }

        var sha: String?
        if let request = Self.request(Self.path, key: key),
           let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sha = existing["sha"] as? String
        }

        let payload: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: .now), "events": events.map { $0.dictionary }]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              var request = Self.request(Self.path, key: key) else { return }
        var put: [String: Any] = ["message": "Shelf feedback", "content": body.base64EncodedString()]
        if let sha { put["sha"] = sha }
        request.httpMethod = "PUT"
        request.httpBody = try? JSONSerialization.data(withJSONObject: put)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            dirty = false
            lastSent = .now
            UserDefaults.standard.set(lastSent, forKey: "feedbackSent")
        } else if status == 401 {
            // The key was removed or ran out on GitHub's side.
            disconnect()
        }
    }

    private static func request(_ path: String, key: String) -> URLRequest? {
        let suffix = path.isEmpty ? "" : "/contents/\(path)"
        guard let url = URL(string: "https://api.github.com/repos/\(repository)\(suffix)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
}

private extension Feedback.Event {
    var dictionary: [String: Any] {
        ["kind": kind.rawValue, "url": url, "title": title, "site": site, "at": ISO8601DateFormatter().string(from: at)]
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
