import UIKit
import WebKit

/// Shows sign-in windows ("Continue with Apple", Google and so on) as real pop-up windows on top
/// of the page, so they can hand the login back to the page that opened them and close themselves.
@MainActor
final class WebPopups: NSObject, WKUIDelegate {
    /// Sign-in services whose new windows must stay real pop-ups.
    static let signInHosts = ["appleid.apple.com", "idmsa.apple.com", "accounts.google.com", "facebook.com", "login.microsoftonline.com"]

    /// Whether a new-window request is a sign-in pop-up rather than an ordinary link.
    static func isSignIn(_ action: WKNavigationAction, _ features: WKWindowFeatures) -> Bool {
        if features.width != nil || features.height != nil { return true }
        guard let host = action.request.url?.host?.lowercased() else { return true }
        return signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Opens the pop-up over `parent`. WebKit loads the request into the returned view itself.
    func open(over parent: WKWebView, configuration: WKWebViewConfiguration) -> WKWebView {
        let container = UIView(frame: parent.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .systemBackground

        let close = UIButton(type: .system, primaryAction: UIAction(title: "Close") { [weak container] _ in
            container?.removeFromSuperview()
        })
        close.titleLabel?.font = .preferredFont(forTextStyle: .body)
        close.translatesAutoresizingMaskIntoConstraints = false

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popup.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(close)
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            close.heightAnchor.constraint(equalToConstant: 36),
            popup.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 4),
            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            popup.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        parent.addSubview(container)
        return popup
    }

    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            if Self.isSignIn(navigationAction, windowFeatures) {
                return open(over: webView, configuration: configuration)
            }
            if navigationAction.targetFrame == nil { _ = webView.load(navigationAction.request) }
            return nil
        }
    }

    /// The sign-in finished and the page called window.close().
    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if let container = webView.superview, container.superview is WKWebView { container.removeFromSuperview() }
        }
    }
}
