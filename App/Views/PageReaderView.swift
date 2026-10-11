import SwiftUI
import WebKit

/// Shows an article's real web page inside Shelf, signed in with Ian's saved logins, and quietly
/// picks up the full text as soon as it appears. If the site asks him to log in, he does it right
/// here, once, and Shelf remembers it.
struct PageReaderView: View {
    let article: Article
    var onCaptured: () -> Void = {}
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var captured = false
    @StateObject private var capture = CaptureModel()

    var body: some View {
        NavigationStack {
            Group {
                if let url = article.url {
                    PageCaptureWebView(url: url, model: capture) { extracted, pageURL in
                        guard !captured else { return }
                        captured = true
                        Task { await library.applyCaptured(extracted, to: article, from: pageURL) }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        Task {
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            onCaptured()
                            dismiss()
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("No link to open", systemImage: "link")
                }
            }
            .onDisappear { Task { await SignInWebView.shareCookies() } }
            .navigationTitle(article.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let url = article.url {
                    ToolbarItem(placement: .primaryAction) {
                        Button { OriginalOpener.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                            .accessibilityLabel("Open in app")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    if captured {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        Text("Got the full article")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Shelf grabs the text once the article shows. If the site asks, log in here once.")
                        if capture.latest != nil {
                            Spacer(minLength: 4)
                            Button("Use this page") { capture.useLatest() }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .animation(.default, value: captured)
            }
        }
    }
}

/// What the page has shown so far, so Ian can take it by hand if Shelf isn't sure it's complete.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var latest: ExtractedArticle?
    var latestURL: URL?
    var deliver: ((ExtractedArticle, URL) -> Void)?

    func useLatest() {
        guard let latest, let latestURL else { return }
        deliver?(latest, latestURL)
    }
}

/// The visible browser. After each page load, and every couple of seconds after (pages often fill
/// in late, or after a login), it checks whether the whole article is on screen yet.
struct PageCaptureWebView: UIViewRepresentable {
    let url: URL
    let model: CaptureModel
    let onArticle: (ExtractedArticle, URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, model: model, onArticle: onArticle) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = BrowserReader.safariName
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: url))
        context.coordinator.startChecking()
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let url: URL
        let model: CaptureModel
        let onArticle: (ExtractedArticle, URL) -> Void
        weak var webView: WKWebView?
        private var loop: Task<Void, Never>?
        private var done = false
        private var checking = false

        init(url: URL, model: CaptureModel, onArticle: @escaping (ExtractedArticle, URL) -> Void) {
            self.url = url
            self.model = model
            self.onArticle = onArticle
            super.init()
            model.deliver = { [weak self] article, pageURL in self?.deliver(article, from: pageURL) }
        }

        func startChecking() {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.check()
                }
            }
        }

        func stop() {
            loop?.cancel()
            loop = nil
        }

        private func deliver(_ article: ExtractedArticle, from pageURL: URL) {
            guard !done else { return }
            done = true
            stop()
            onArticle(article, pageURL)
        }

        func check() async {
            guard !done, !checking, let webView, !webView.isLoading else { return }
            checking = true
            defer { checking = false }
            // Judge by where the page actually is (an Apple News link ends up at the publisher).
            let pageURL = webView.url ?? url
            let script = BrowserReader.captureScript(Extractor.shared.pageScripts, url: pageURL.absoluteString)
            guard let json = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String,
                  let article = try? JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8)),
                  article.hasReadableText else { return }
            if model.latest == nil || article.wordCount >= (model.latest?.wordCount ?? 0) {
                model.latest = article
                model.latestURL = pageURL
            }
            // On subscription sites a short piece can't be told apart from a teaser, so for those
            // Ian taps "Use this" himself.
            if article.isComplete(for: pageURL) {
                deliver(article, from: pageURL)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    await self.check()
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Stay inside the page: no jumping out to other apps from in here.
            let allow = MainActor.assumeIsolated {
                ["http", "https", "about", "blob", "data"].contains(navigationAction.request.url?.scheme ?? "")
            }
            decisionHandler(allow ? .allow : .cancel)
        }

        private let popups = WebPopups()

        /// "Sign in with Apple/Google" open as real pop-ups; other new-window links open in this view.
        nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            MainActor.assumeIsolated {
                popups.webView(webView, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
            }
        }

        nonisolated func webViewDidClose(_ webView: WKWebView) {
            MainActor.assumeIsolated { popups.webViewDidClose(webView) }
        }
    }
}

/// Opens a link in its own app (the NYT app, X and so on) when it's installed, otherwise Safari.
enum OriginalOpener {
    @MainActor
    static func open(_ url: URL) {
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened { UIApplication.shared.open(url) }
        }
    }
}
