import Foundation
import Security

/// A small shared space the app, the Share button and the widgets can all read and write.
///
/// It lives in the iPhone's keychain, in a group only Shelf's own parts can see. (This avoids
/// a separate "App Group" set-up step on Apple's developer website.)
enum SharedVault {
    static let accessGroup: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "ShelfKeychainGroup") as? String
        // In unsigned simulator builds the team prefix is missing; fall back to the app's own keychain.
        guard let value, !value.hasPrefix("."), !value.contains("$(") else { return nil }
        return value
    }()

    private static func baseQuery(service: String, account: String?, useGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if useGroup, let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    @discardableResult
    static func write(_ data: Data, service: String, account: String) -> Bool {
        for useGroup in [true, false] {
            var query = baseQuery(service: service, account: account, useGroup: useGroup)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return true }
            if status != errSecMissingEntitlement { return false }
        }
        return false
    }

    static func read(service: String, account: String) -> Data? {
        for useGroup in [true, false] {
            var query = baseQuery(service: service, account: account, useGroup: useGroup)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { return result as? Data }
            if status != errSecMissingEntitlement { return nil }
        }
        return nil
    }

    /// All items stored under a service, as (account, data) pairs.
    static func readAll(service: String) -> [(String, Data)] {
        for useGroup in [true, false] {
            var query = baseQuery(service: service, account: nil, useGroup: useGroup)
            query[kSecReturnData as String] = true
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let items = result as? [[String: Any]] {
                return items.compactMap { item in
                    guard let account = item[kSecAttrAccount as String] as? String,
                          let data = item[kSecValueData as String] as? Data else { return nil }
                    return (account, data)
                }
            }
            if status != errSecMissingEntitlement { return [] }
        }
        return []
    }

    static func delete(service: String, account: String) {
        for useGroup in [true, false] {
            SecItemDelete(baseQuery(service: service, account: account, useGroup: useGroup) as CFDictionary)
        }
    }
}

private extension Data {
    func shelfCompressed() -> Data { (try? (self as NSData).compressed(using: .zlib) as Data) ?? self }
    func shelfDecompressed() -> Data { (try? (self as NSData).decompressed(using: .zlib) as Data) ?? self }
}

/// Saved-but-not-yet-imported items from the Share button.
enum Inbox {
    private static let service = "shelf.inbox"

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

    @discardableResult
    static func write(_ item: InboxItem) -> Bool {
        guard let data = try? encoder.encode(item) else { return false }
        return SharedVault.write(data.shelfCompressed(), service: service, account: item.id.uuidString)
    }

    static func items() -> [InboxItem] {
        SharedVault.readAll(service: service)
            .compactMap { try? decoder.decode(InboxItem.self, from: $0.1.shelfDecompressed()) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func remove(_ id: UUID) {
        SharedVault.delete(service: service, account: id.uuidString)
    }
}

enum SnapshotStore {
    private static let service = "shelf.widget"

    static func read() -> WidgetSnapshot {
        guard let data = SharedVault.read(service: service, account: "snapshot"),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        SharedVault.write(data, service: service, account: "snapshot")
    }
}

/// Sites Ian has signed in to inside Shelf, and their sign-in cookies, so the Share button can
/// fetch subscriber articles too.
enum SubscribedSites {
    private static let service = "shelf.sites"

    static var all: [String] {
        guard let data = SharedVault.read(service: service, account: "list"),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func add(_ host: String) {
        var list = all
        if !list.contains(host) { list.append(host) }
        save(list.sorted())
    }

    static func remove(_ host: String) {
        save(all.filter { $0 != host })
    }

    private static func save(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            SharedVault.write(data, service: service, account: "list")
        }
    }

    /// Keeps only the cookies belonging to subscribed sites.
    static func storeCookies(_ cookies: [HTTPCookie]) {
        let hosts = all
        let relevant = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) || domain.hasSuffix("." + $0) }
        }
        let properties = relevant.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            return props.reduce(into: [String: Any]()) { result, pair in
                result[pair.key.rawValue] = pair.value
            }
        }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: properties, requiringSecureCoding: false) {
            SharedVault.write(data, service: service, account: "cookies")
        }
    }

    /// Loads the shared sign-in cookies into this process's cookie store.
    static func loadCookies(into storage: HTTPCookieStorage) {
        guard let data = SharedVault.read(service: service, account: "cookies"),
              let list = (try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)) as? [[String: Any]] else { return }
        for props in list {
            let keyed = Dictionary(uniqueKeysWithValues: props.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: keyed) { storage.setCookie(cookie) }
        }
    }
}
