import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sites = SubscribedSites.all
    @State private var addingSite = false
    @State private var newSite = ""
    @State private var signingIn: SignInTarget?

    struct SignInTarget: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sites, id: \.self) { host in
                        Button {
                            if let url = URL(string: "https://\(host)") { signingIn = SignInTarget(url: url) }
                        } label: {
                            HStack {
                                Text(host).foregroundStyle(.primary)
                                Spacer()
                                Text("Signed in").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { SubscribedSites.remove(sites[index]) }
                        sites = SubscribedSites.all
                    }
                    Button {
                        newSite = ""
                        addingSite = true
                    } label: {
                        Label("Add a site", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Sites I subscribe to")
                } footer: {
                    Text("Sign in once to a site you pay for, and Shelf will save its full articles, even when you share from that site's own app. Articles shared from Safari already come through in full.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Add a site", isPresented: $addingSite) {
                TextField("For example, thetimes.com", text: $newSite)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Sign in") {
                    let cleaned = newSite.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let address = cleaned.hasPrefix("http") ? cleaned : "https://\(cleaned)"
                    if let url = URL(string: address), url.host != nil { signingIn = SignInTarget(url: url) }
                }
            } message: {
                Text("Type the website's address. You'll sign in to it on the next screen.")
            }
            .sheet(item: $signingIn) { target in
                SignInView(startURL: target.url) {
                    SubscribedSites.add(target.url.shelfHostName)
                    sites = SubscribedSites.all
                }
            }
        }
    }
}

/// A simple browser for signing in to a news site. Its cookies are shared with the Share button.
struct SignInView: View {
    let startURL: URL
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInWebView(url: startURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(startURL.shelfHostName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task { @MainActor in
                                onDone()
                                await SignInWebView.shareCookies()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
                .safeAreaInset(edge: .top) {
                    Text("Sign in as you normally would, then tap Done.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
        }
    }
}

struct SignInWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Copies sign-in cookies to the shared store the app and Share button fetch with.
    @MainActor
    static func shareCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        SubscribedSites.storeCookies(cookies)
    }
}
