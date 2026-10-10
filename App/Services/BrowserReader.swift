import Foundation
import UIKit
import WebKit

/// A hidden, full browser for pages that only show their text to real browsers or signed-in
/// readers. It shares the sign-ins Ian made under "Sites I subscribe to".
@MainActor
final class BrowserReader: NSObject, WKNavigationDelegate {
    static let shared = BrowserReader()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Bool, Never>?
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
        defer { view.stopLoading(); view.loadHTMLString("", baseURL: nil) }
        guard loaded else { return nil }
        // Give the page a moment to fill in text that arrives after loading.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let expression = "shelfExtract(document, \(Extractor.jsString(view.url?.absoluteString ?? url.absoluteString)))"
        let result = try? await view.evaluateJavaScript("(function(){\n" + script + "\n;\nreturn " + expression + ";\n})()")
        return result as? String
    }

    private func makeView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = false
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

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Follow the page's own redirects, but never open other apps or pop-ups.
        let allow = MainActor.assumeIsolated {
            navigationAction.targetFrame != nil && ["http", "https", "about"].contains(navigationAction.request.url?.scheme ?? "")
        }
        decisionHandler(allow ? .allow : .cancel)
    }
}
