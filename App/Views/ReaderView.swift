import SwiftUI
import SwiftData

/// Looks up the article and shows the right screen for its state.
struct ReaderContainer: View {
    let id: UUID
    @EnvironmentObject private var library: Library

    var body: some View {
        if let article = library.article(id: id) {
            ReaderView(article: article)
        } else {
            ContentUnavailableView("Article not found", systemImage: "questionmark.folder")
        }
    }
}

struct ReaderView: View {
    @Bindable var article: Article
    @EnvironmentObject private var library: Library
    @StateObject private var speaker = Speaker.shared

    @AppStorage("readerTextSize") private var textSize: Double = 19
    @AppStorage("readerTheme") private var themeRaw: String = ReaderTheme.automatic.rawValue
    @State private var showAppearance = false
    @State private var furthest = 0
    @State private var restored = false
    @State private var showPage = false
    @State private var offeredPage = false

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .automatic }

    var body: some View {
        Group {
            switch article.status {
            case .ready:
                content
            case .pending where article.blockCount > 0:
                content
            case .pending:
                waiting
            case .failed, .linkOnly:
                fallback
            }
        }
        .background((theme.background ?? Color(.systemBackground)).ignoresSafeArea())
        .foregroundStyle(theme.text ?? Color.primary)
        .preferredColorScheme(theme.colorScheme)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarBackground(theme.background ?? Color(.systemBackground), for: .navigationBar)
        .sheet(isPresented: $showAppearance) {
            AppearanceSheet(textSize: $textSize, themeRaw: $themeRaw)
                .presentationDetents([.height(250)])
                .presentationDragIndicator(.visible)
        }
        .task(id: article.id) {
            if article.status == .pending {
                await library.prepare(article)
            }
            openPageIfNeeded()
        }
        .onChange(of: article.statusRaw) { _, _ in openPageIfNeeded() }
        .sheet(isPresented: $showPage) {
            PageReaderView(article: article)
        }
        .onDisappear { saveProgress() }
    }

    /// When Shelf couldn't get the text by itself, show the real page straight away so it can
    /// pick the text up there (one tap for Ian instead of two).
    /// Shelf couldn't get the text by itself, but the page itself may show it.
    private var needsPage: Bool {
        guard let url = article.url, !url.isPost else { return false }
        return article.status == .failed || (article.status == .linkOnly && url.isPaywalledSite)
    }

    private func openPageIfNeeded() {
        guard !offeredPage, needsPage else { return }
        offeredPage = true
        showPage = true
    }

    // MARK: Reading

    private var content: some View {
        let blocks = article.blocks
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: textSize * 0.9) {
                    header
                        .id(-1)
                    if article.isPartial {
                        partialBanner
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        BlockView(block: block, textSize: textSize, theme: theme)
                            .id(index)
                            .onAppear {
                                if index > furthest { furthest = index }
                                if index == blocks.count - 1 && !article.isRead {
                                    library.setRead(article, true)
                                }
                            }
                    }
                    footer
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 60)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ProgressView(value: blocks.count > 1 ? Double(furthest) / Double(blocks.count - 1) : 0)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .scaleEffect(x: 1, y: 0.6, anchor: .bottom)
            }
            .onAppear {
                guard !restored else { return }
                restored = true
                furthest = article.progressIndex
                if article.progressIndex > 2 && !article.isRead {
                    DispatchQueue.main.async { proxy.scrollTo(article.progressIndex, anchor: .center) }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(([article.sourceName.uppercased()] + (article.minutes.map { ["\($0) MIN READ"] } ?? [])).joined(separator: " · "))
                .font(.caption.weight(.medium))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text(article.title)
                .font(.system(size: textSize * 1.55, weight: .bold, design: .serif))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let byline = article.byline, !byline.isEmpty {
                Text(byline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let lead = article.leadImage.flatMap(URL.init(string:)),
               !article.blocks.contains(where: { $0.t == .image }) {
                CachedImage(url: lead) { Color.secondary.opacity(0.1).frame(height: 200) }
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 4)
    }

    private var partialBanner: some View {
        Button { showPage = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.open")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only the start came through")
                        .font(.subheadline.weight(.semibold))
                    Text("Tap to load the full article with your subscription")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text ?? Color.primary)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Divider().padding(.vertical, 8)
            if let url = article.url {
                Button {
                    OriginalOpener.open(url)
                } label: {
                    Label(url.isPost ? "Open in X" : "Open in app", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
            if article.origin == .recommended {
                HStack(spacing: 10) {
                    Text("Good pick?").font(.subheadline).foregroundStyle(.secondary)
                    ThumbButtons(article: article)
                }
                .padding(.top, 4)
            }
            if article.origin == .recommended, let url = article.url {
                Button {
                    library.save(url: url)
                } label: {
                    Label("Save to Shelf", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Other states

    private var waiting: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Getting the article ready…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fallback: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.sourceName.uppercased())
                    .font(.caption.weight(.medium))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text(article.title)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                if let lead = article.leadImage.flatMap(URL.init(string:)) {
                    CachedImage(url: lead) { Color.secondary.opacity(0.1).frame(height: 180) }
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block, textSize: textSize, theme: theme)
                }
                if article.blocks.isEmpty, let excerpt = article.excerpt {
                    Text(excerpt)
                        .font(.system(size: textSize, design: .serif))
                        .lineSpacing(textSize * 0.45)
                }
                Text(article.status == .failed
                     ? "Shelf couldn't get the text by itself. Tap Read it here to load the page in Shelf; if the site asks you to log in, do it once and Shelf will remember."
                     : "There's no article text on this page, so it opens in its own app or Safari.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                HStack {
                    if needsPage {
                        Button { showPage = true } label: {
                            Label("Read it here", systemImage: "doc.text")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    if let url = article.url {
                        Button { OriginalOpener.open(url) } label: {
                            Label(url.isPost ? "Open in X" : "Open in app", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                }
            }
            .padding(22)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showAppearance = true } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel("Text size and colour")
            if article.status == .ready {
                Button { speaker.toggle(article) } label: {
                    Image(systemName: speaker.speakingID == article.id && !speaker.isPaused ? "pause.circle" : "speaker.wave.2")
                }
                .accessibilityLabel(speaker.speakingID == article.id ? "Pause reading aloud" : "Read aloud")
            }
            Menu {
                if let url = article.url {
                    ShareLink(item: url)
                    Button { OriginalOpener.open(url) } label: { Label("Open in App", systemImage: "arrow.up.forward.app") }
                    if !url.isPost {
                        Button { showPage = true } label: { Label("Load Full Page in Shelf", systemImage: "doc.text") }
                    }
                }
                Button { library.toggleFavorite(article) } label: {
                    Label(article.isFavorite ? "Unfavourite" : "Favourite", systemImage: article.isFavorite ? "star.fill" : "star")
                }
                Button { library.setRead(article, !article.isRead) } label: {
                    Label(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? "circle" : "checkmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    private func saveProgress() {
        if furthest > article.progressIndex {
            article.progressIndex = furthest
            try? library.context.save()
        }
    }
}

struct BlockView: View {
    let block: Block
    let textSize: Double
    let theme: ReaderTheme

    var body: some View {
        switch block.t {
        case .heading:
            Text(block.text ?? "")
                .font(.system(size: textSize * 1.2, weight: .bold, design: .serif))
                .padding(.top, textSize * 0.4)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            Text(block.text ?? "")
                .font(.system(size: textSize, design: .serif))
                .lineSpacing(textSize * 0.45)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .quote:
            HStack(alignment: .top, spacing: 14) {
                Capsule().fill(Color.blue.opacity(0.6)).frame(width: 3)
                Text(block.text ?? "")
                    .font(.system(size: textSize, design: .serif).italic())
                    .lineSpacing(textSize * 0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").font(.system(size: textSize, design: .serif))
                Text(block.text ?? "")
                    .font(.system(size: textSize, design: .serif))
                    .lineSpacing(textSize * 0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preformatted:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text ?? "")
                    .font(.system(size: textSize * 0.8, design: .monospaced))
                    .padding(12)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case .image:
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: block.src.flatMap(URL.init(string:))) {
                    Rectangle().fill(Color.secondary.opacity(0.08)).frame(height: 200)
                }
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let caption = block.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct AppearanceSheet: View {
    @Binding var textSize: Double
    @Binding var themeRaw: String

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "textformat.size.smaller")
                Slider(value: $textSize, in: 15...28, step: 1)
                    .tint(.blue)
                Image(systemName: "textformat.size.larger")
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(ReaderTheme.allCases) { theme in
                    Button {
                        themeRaw = theme.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(swatch(theme))
                                .overlay(Circle().stroke(themeRaw == theme.rawValue ? Color.blue : Color.secondary.opacity(0.3), lineWidth: themeRaw == theme.rawValue ? 3 : 1))
                                .frame(width: 44, height: 44)
                            Text(theme.label).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(24)
    }

    private func swatch(_ theme: ReaderTheme) -> AnyShapeStyle {
        switch theme {
        case .automatic: return AnyShapeStyle(LinearGradient(colors: [.white, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .light: return AnyShapeStyle(Color.white)
        case .sepia: return AnyShapeStyle(theme.background ?? .white)
        case .dark: return AnyShapeStyle(Color.black)
        }
    }
}
