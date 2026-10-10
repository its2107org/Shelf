import UIKit
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

/// The little "Saved to Shelf" card that appears when Ian taps Share, then Shelf.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = SaveCardModel()
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let host = UIHostingController(rootView: SaveCardView(model: model) { [weak self] in self?.finish() })
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Extractor.shared.hostView = view

        Task { @MainActor in
            await save()
        }
    }

    @MainActor
    private func save() async {
        let shared = await SharedContent.read(from: extensionContext)
        guard shared.url != nil || shared.text != nil else {
            model.state = .failed("There was nothing to save here.")
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            finish()
            return
        }

        var item = InboxItem(
            id: UUID(),
            url: shared.url?.absoluteString,
            title: shared.title ?? shared.url?.shelfHostName,
            sharedText: shared.text,
            createdAt: .now,
            extracted: shared.article
        )
        model.title = item.title ?? "Saved"

        // Save straight away so nothing is lost, even if the text takes a moment.
        Inbox.write(item)
        bumpWidget(title: item.title ?? "Saved", source: shared.url?.shelfHostName ?? "Note", id: item.id)

        // Safari already gave us the article as shown on screen (with any subscriber login).
        if let article = shared.article, article.hasReadableText {
            if let title = article.title, !title.isEmpty { model.title = title }
        } else if let url = shared.url {
            let started = Date()
            let extracted: ExtractedArticle? = await withTaskGroup(of: ExtractedArticle?.self) { group in
                group.addTask { @MainActor in
                    try? await Extractor.shared.fetchAndExtract(url)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let extracted {
                item.extracted = extracted
                if let title = extracted.title, !title.isEmpty {
                    item.title = title
                    model.title = title
                }
            }
            // If it wasn't ready in time, the app finishes it next time it opens.
            Inbox.write(item)
            bumpWidget(title: item.title ?? "Saved", source: shared.url?.shelfHostName ?? "Note", id: item.id, adding: false)
            // Keep the card on screen long enough to read.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.4 { try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000)) }
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.state = .saved }
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        finish()
    }

    private func bumpWidget(title: String, source: String, id: UUID, adding: Bool = true) {
        var snapshot = SnapshotStore.read()
        if adding { snapshot.unreadCount += 1 }
        snapshot.next = WidgetSnapshot.Next(id: id, title: title, source: source, minutes: nil)
        snapshot.updatedAt = .now
        SnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        UIView.animate(withDuration: 0.2, animations: { self.view.alpha = 0 }) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

/// What another app handed us: a link, its title, Safari's copy of the page, or plain text.
struct SharedContent {
    var url: URL?
    var title: String?
    var text: String?
    var article: ExtractedArticle?

    @MainActor
    static func read(from context: NSExtensionContext?) async -> SharedContent {
        var result = SharedContent()
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if result.title == nil, let title = item.attributedContentText?.string, !title.isEmpty, title.count < 300 {
                result.title = title
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let dict = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? [String: Any],
                   let page = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    if let u = page["url"] as? String { result.url = URL(string: u) }
                    if let t = page["title"] as? String, !t.isEmpty { result.title = t }
                    if let json = page["article"] as? String {
                        result.article = try? JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8))
                    }
                }
                if result.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.hasPrefix("http") == true {
                    result.url = url
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    result.text = (result.text.map { $0 + "\n\n" } ?? "") + text
                }
            }
        }
        // Many apps share "Headline https://link" as text; pull the link out.
        if result.url == nil, let text = result.text {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let match = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            if let match, let url = match.url, url.scheme?.hasPrefix("http") == true {
                result.url = url
                let remainder = (text as NSString).replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                result.text = remainder.isEmpty ? nil : remainder
                if result.title == nil, let remaining = result.text, remaining.count < 200 { result.title = remaining }
            }
        }
        if result.title == result.url?.absoluteString { result.title = nil }
        return result
    }
}

@MainActor
final class SaveCardModel: ObservableObject {
    enum State: Equatable {
        case saving
        case saved
        case failed(String)
    }

    @Published var state: State = .saving
    @Published var title: String = ""
}

struct SaveCardView: View {
    @ObservedObject var model: SaveCardModel
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture(perform: onTap)
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue).frame(width: 56, height: 56)
                    switch model.state {
                    case .saving:
                        ProgressView().tint(.white)
                    case .saved:
                        Image(systemName: "checkmark")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    case .failed:
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Text(heading)
                    .font(.title3.weight(.bold))
                if case .failed(let message) = model.state {
                    Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if !model.title.isEmpty {
                    Text(model.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                if model.state == .saved {
                    Text("Ready to read in Shelf")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
            .onTapGesture(perform: onTap)
        }
    }

    private var heading: String {
        switch model.state {
        case .saving: return "Saving…"
        case .saved: return "Saved to Shelf"
        case .failed: return "Couldn't save"
        }
    }
}
