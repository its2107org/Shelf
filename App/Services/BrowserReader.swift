import Foundation
import UIKit
import WebKit

/// A hidden, full browser for pages that only show their text to real browsers or signed-in
/// readers. It shares the sign-ins Ian made under "Sites I subscribe to".
@MainActor
final class BrowserReader: NSObject, WKNavigationDelegate {
    static let shared = BrowserReader()

    /// Makes the hidden browser introduce itself exactly like Safari, which some sites insist on.
    static let safariName = "Version/26.0 Mobile/15E148 Safari/604.1"

    /// Script that pulls the article out of the page that's open, in its own private scope.
    static func captureScript(_ scripts: String, url: String) -> String {
        "(function(){\n" + scripts + "\n;\nreturn shelfExtract(document, " + Extractor.jsString(url) + ");\n})()"
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var cleanup: WKNavigation?
    private var generation = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func read(_ url: URL, script: String) async -> String? {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }

        let view = makeView()
        generation += 1
        let current = generation
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            view.load(URLRequest(url: url, timeoutInterval: 20))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.generation == current else { return }
                self.finish(false)
            }
        }
        defer { view.stopLoading(); cleanup = view.loadHTMLString("", baseURL: nil) }
        guard loaded else { return nil }
        // Pages often fill in after loading, and "checking you're human" screens move on by
        // themselves after a few seconds, so look a few times and keep the fullest result.
        var best: (json: String, words: Int)?
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let pageURL = view.url ?? url
            guard let json = try? await view.evaluateJavaScript(Self.captureScript(script, url: pageURL.absoluteString), in: nil, contentWorld: .defaultClient) as? String,
                  let article = try? JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8)) else { continue }
            if article.hasReadableText, article.wordCount > (best?.words ?? -1) {
                best = (json, article.wordCount)
            }
            if article.isComplete(for: pageURL) { break }
        }
        return best?.json
    }

    private func makeView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = false
        config.applicationNameForUserAgent = BrowserReader.safariName
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        // WebKit slows hidden pages right down unless they're in a window.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        if let window {
            view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            window.insertSubview(view, at: 0)
        }
        webView = view
        return view
    }

    private func finish(_ ok: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        generation += 1
        continuation.resume(returning: ok)
    }

    /// A page replacing itself (redirects, sign-in hops) cancels the earlier load; that's not a failure.
    nonisolated static func ignorable(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) || (error.domain == WKErrorDomain && error.code == 102)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard navigation !== cleanup else { return }
            finish(true)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            guard navigation !== cleanup, !Self.ignorable(error) else { return }
            finish(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            guard navigation !== cleanup, !Self.ignorable(error) else { return }
            finish(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Follow the page's own redirects, but never open other apps or pop-ups.
        let allow = MainActor.assumeIsolated {
            navigationAction.targetFrame != nil && ["http", "https", "about"].contains(navigationAction.request.url?.scheme ?? "")
        }
        decisionHandler(allow ? .allow : .cancel)
    }
}
