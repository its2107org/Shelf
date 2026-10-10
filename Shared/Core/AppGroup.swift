import Foundation

/// The shared space the app, the Share button and the widgets all read and write.
enum AppGroup {
    static let identifier: String = {
        Bundle.main.object(forInfoDictionaryKey: "ShelfAppGroup") as? String ?? "group.com.shelf"
    }()

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // Simulator builds without signing have no group container; fall back to a private folder.
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharedFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// Cookies for sites Ian signs in to, shared so the Share button can fetch subscriber articles.
    static var cookieStorage: HTTPCookieStorage {
        HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: identifier)
    }
}

/// Saved-but-not-yet-imported items, one small file each.
enum Inbox {
    private static var folder: URL {
        let url = AppGroup.containerURL.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write(_ item: InboxItem) throws {
        let data = try encoder.encode(item)
        try data.write(to: folder.appendingPathComponent("\(item.id.uuidString).json"), options: .atomic)
    }

    static func items() -> [InboxItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(InboxItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
    }

    static var count: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }
}

enum SnapshotStore {
    private static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("widget.json") }

    static func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Sites Ian has signed in to inside Shelf.
enum SubscribedSites {
    private static let key = "subscribedSites"

    static var all: [String] {
        AppGroup.defaults.stringArray(forKey: key) ?? []
    }

    static func add(_ host: String) {
        var list = all
        if !list.contains(host) { list.append(host) }
        AppGroup.defaults.set(list.sorted(), forKey: key)
    }

    static func remove(_ host: String) {
        AppGroup.defaults.set(all.filter { $0 != host }, forKey: key)
    }
}
