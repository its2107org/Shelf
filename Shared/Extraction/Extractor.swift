import Foundation
import UIKit
import WebKit

enum ExtractorError: Error {
    case badResponse
    case timedOut
    case notReadable
}

/// Turns links into clean reading text.
///
/// Pages are parsed by a hidden web view with the page's own scripts switched off and every
/// download blocked, so it's quick and nothing on the page can run. Readability (the engine
/// behind Firefox's Reader View) then picks out the article.
@MainActor
final class Extractor: NSObject {
    static let shared = Extractor()

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private lazy var scripts: String = {
        let bundle = Bundle(for: Extractor.self)
        return ["Readability", "ShelfExtract"].compactMap { name in
            bundle.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n;\n")
    }()

    private var ruleList: WKContentRuleList?
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadGeneration = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Set by the app (not the Share card) to read stubborn pages in a full hidden browser.
    static var browser: ((URL, String) async -> String?)?

    /// Optional view to host the hidden web view in (keeps WebKit from pausing it).
    weak var hostView: UIView?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        SubscribedSites.loadCookies(into: HTTPCookieStorage.shared)
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": Extractor.userAgent,
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ",")
        ]
        return URLSession(configuration: config)
    }()

    // MARK: Public

    /// Fetches a link and extracts it. Posts on X use X's public embed, which needs no login.
    func fetchAndExtract(_ url: URL) async throws -> ExtractedArticle {
        if url.isPost {
            return try await extractPost(url)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            // Some sites (the New York Times, for one) turn away anything that isn't a real browser.
            return try await viaBrowser(url, otherwise: ExtractorError.badResponse)
        }
        if let mime = http.mimeType, !mime.contains("html") && !mime.contains("xml") {
            throw ExtractorError.notReadable
        }
        let html = Self.decode(data, encodingName: http.textEncodingName)
        let article = try await extract(html: html, url: http.url ?? url)
        if article.hasReadableText { return article }
        // The text may only appear once the page's own scripts run, or once signed in.
        return (try? await viaBrowser(url, otherwise: ExtractorError.notReadable)) ?? article
    }

    /// Opens the page in a real, hidden browser (signed in to Ian's subscribed sites) and reads it
    /// once loaded. Slower, so only used when the quick way doesn't work. Not used in the Share card.
    private func viaBrowser(_ url: URL, otherwise error: Error) async throws -> ExtractedArticle {
        guard let browser = Extractor.browser, let json = await browser(url, scripts) else { throw error }
        let article = try JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8))
        guard article.hasReadableText else { throw ExtractorError.notReadable }
        return article
    }

    /// Extracts an already-downloaded page (for example, one captured from Safari).
    func extract(html: String, url: URL) async throws -> ExtractedArticle {
        let json = try await runInPage(html: html, baseURL: url, expression: "shelfExtract(document, \(Self.jsString(url.absoluteString)))")
        return try JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8))
    }

    // MARK: Posts on X

    private struct OEmbed: Decodable {
        var author_name: String?
        var html: String
    }

    private func extractPost(_ url: URL) async throws -> ExtractedArticle {
        var components = URLComponents(string: "https://publish.twitter.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "omit_script", value: "true"),
            URLQueryItem(name: "dnt", value: "true")
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ExtractorError.badResponse }
        let embed = try JSONDecoder().decode(OEmbed.self, from: data)
        let author = embed.author_name ?? "X"
        let json = try await runInPage(
            html: "<html><body></body></html>",
            baseURL: URL(string: "https://x.com/")!,
            expression: "shelfPost(\(Self.jsString(embed.html)), \(Self.jsString(author)))"
        )
        return try JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8))
    }

    // MARK: Web view plumbing

    private func runInPage(html: String, baseURL: URL, expression: String) async throws -> String {
        await acquire()
        defer { release() }

        let webView = try await makeWebViewIfNeeded()
        loadGeneration += 1
        let generation = loadGeneration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.loadGeneration == generation, self.loadContinuation != nil else { return }
                webView.stopLoading()
                self.finishLoad(ExtractorError.timedOut)
            }
        }
        let result = try await webView.evaluateJavaScript(scripts + "\n;\n" + expression)
        guard let json = result as? String else { throw ExtractorError.notReadable }
        return json
    }

    private func makeWebViewIfNeeded() async throws -> WKWebView {
        if let webView { return webView }
        if ruleList == nil {
            let rules = """
            [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document","popup","fetch","websocket","other","ping"]},"action":{"type":"block"}}]
            """
            ruleList = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ShelfBlockAll", encodedContentRuleList: rules)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        if let ruleList { config.userContentController.add(ruleList) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        if let host = hostView {
            view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            host.addSubview(view)
        }
        webView = view
        return view
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func finishLoad(_ error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    // MARK: Helpers

    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

extension Extractor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad(error) }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the page itself; no frames, pop-ups or redirects to elsewhere.
        let allow = MainActor.assumeIsolated { navigationAction.targetFrame?.isMainFrame == true && navigationAction.navigationType == .other }
        decisionHandler(allow ? .allow : .cancel)
    }
}

