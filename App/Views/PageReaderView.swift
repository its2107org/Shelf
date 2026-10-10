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

    var body: some View {
        NavigationStack {
            Group {
                if let url = article.url {
                    PageCaptureWebView(url: url) { extracted in
                        guard !captured else { return }
                        captured = true
                        Task { await library.applyCaptured(extracted, to: article, from: url) }
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
            .navigationTitle(article.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await SignInWebView.shareCookies() }
                        dismiss()
                    }
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

/// The visible browser. After each page load, and every couple of seconds after (pages often fill
/// in late, or after a login), it checks whether the whole article is on screen yet.
struct PageCaptureWebView: UIViewRepresentable {
    let url: URL
    let onArticle: (ExtractedArticle) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onArticle: onArticle) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = BrowserReader.safariName
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
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
    final class Coordinator: NSObject, WKNavigationDelegate {
        let url: URL
        let onArticle: (ExtractedArticle) -> Void
        weak var webView: WKWebView?
        private var timer: Timer?
        private var done = false
        private var checking = false

        init(url: URL, onArticle: @escaping (ExtractedArticle) -> Void) {
            self.url = url
            self.onArticle = onArticle
        }

        func startChecking() {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.check() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func check() async {
            guard !done, !checking, let webView, !webView.isLoading else { return }
            checking = true
            defer { checking = false }
            let script = BrowserReader.captureScript(Extractor.shared.pageScripts, url: webView.url?.absoluteString ?? url.absoluteString)
            guard let json = try? await webView.evaluateJavaScript(script) as? String,
                  let article = try? JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8)),
                  article.isComplete(for: url) else { return }
            done = true
            stop()
            onArticle(article)
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
