import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sites = SubscribedSites.all
    @State private var addingSite = false
    @State private var newSite = ""
    @State private var signingIn: SignInTarget?
    @StateObject private var feedback = Feedback.shared
    @State private var connectingFeedback = false
    @State private var feedbackKey = ""
    @State private var feedbackFailed = false

    /// Big news sites, so signing in is one tap instead of typing an address.
    struct PopularSite: Hashable {
        let name: String
        let address: String
    }

    static let popular: [PopularSite] = [
        PopularSite(name: "The New York Times", address: "https://www.nytimes.com"),
        PopularSite(name: "Financial Times", address: "https://www.ft.com"),
        PopularSite(name: "The Wall Street Journal", address: "https://www.wsj.com"),
        PopularSite(name: "The Economist", address: "https://www.economist.com"),
        PopularSite(name: "Bloomberg", address: "https://www.bloomberg.com"),
        PopularSite(name: "The Atlantic", address: "https://www.theatlantic.com"),
        PopularSite(name: "The New Yorker", address: "https://www.newyorker.com"),
        PopularSite(name: "The Washington Post", address: "https://www.washingtonpost.com"),
        PopularSite(name: "The Times", address: "https://www.thetimes.com"),
        PopularSite(name: "The Telegraph", address: "https://www.telegraph.co.uk"),
        PopularSite(name: "The Information", address: "https://www.theinformation.com"),
        PopularSite(name: "Business Insider", address: "https://www.businessinsider.com"),
        PopularSite(name: "Barron's", address: "https://www.barrons.com"),
        PopularSite(name: "Wired", address: "https://www.wired.com"),
        PopularSite(name: "Harvard Business Review", address: "https://hbr.org")
    ]

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
                                Text(Self.popular.first { URL(string: $0.address)?.shelfHostName == host }?.name ?? host).foregroundStyle(.primary)
                                Spacer()
                                Text("Signed in").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let hosts = offsets.map { sites[$0] }
                        hosts.forEach(SubscribedSites.remove)
                        sites = SubscribedSites.all
                        Task { await SignInWebView.signOut(of: hosts) }
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

                let notYet = Self.popular.filter { site in !sites.contains(URL(string: site.address)?.shelfHostName ?? "") }
                if !notYet.isEmpty {
                    Section {
                        ForEach(notYet, id: \.address) { site in
                            Button {
                                if let url = URL(string: site.address) { signingIn = SignInTarget(url: url) }
                            } label: {
                                HStack {
                                    Text(site.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("Log in").font(.subheadline).foregroundStyle(.blue)
                                }
                            }
                        }
                    } header: {
                        Text("Popular news sites")
                    } footer: {
                        Text("Tap one you subscribe to and log in. Shelf keeps you logged in on this iPhone only, and never sees or stores your password.")
                    }
                }

                Section {
                    if feedback.isConnected {
                        LabeledContent("Learning from you", value: "On")
                        Button("Turn off", role: .destructive) { feedback.disconnect() }
                    } else {
                        Button {
                            feedbackKey = ""
                            connectingFeedback = true
                        } label: {
                            Label("Connect your GitHub key", systemImage: "sparkles")
                        }
                    }
                } header: {
                    Text("Smarter For You picks")
                } footer: {
                    Text("Lets the daily picks learn from your thumbs and what you save. Only titles, links and site names are shared, into your private GitHub project. Never article text or logins.")
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
                    // Needs a real site name like "thetimes.com", not just "com".
                    if let url = URL(string: address), url.shelfHostName.split(separator: ".").count >= 2 {
                        signingIn = SignInTarget(url: url)
                    }
                }
            } message: {
                Text("Type the website's address. You'll sign in to it on the next screen.")
            }
            .alert("Connect your GitHub key", isPresented: $connectingFeedback) {
                SecureField("Paste the key here", text: $feedbackKey)
                Button("Cancel", role: .cancel) {}
                Button("Connect") {
                    Task { feedbackFailed = !(await feedback.connect(key: feedbackKey)) }
                }
            } message: {
                Text("Paste the key you made on GitHub for shelf-feedback.")
            }
            .alert("That key didn't work", isPresented: $feedbackFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check it was made for the shelf-feedback project with Contents set to Read and write, then try again.")
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
                    Text("Tap the site's Log in or Sign in button, log in as usual, then tap Done.")
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

    func makeCoordinator() -> WebPopups { WebPopups() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = BrowserReader.safariName
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Forgets the logins for sites Ian removed, everywhere Shelf kept them.
    @MainActor
    static func signOut(of hosts: [String]) async {
        let matches = { (cookie: HTTPCookie) -> Bool in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return hosts.contains { domain == $0 || domain.hasSuffix("." + $0) || $0.hasSuffix("." + domain) }
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await store.allCookies() where matches(cookie) {
            await store.deleteCookie(cookie)
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where matches(cookie) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        await shareCookies()
    }

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
