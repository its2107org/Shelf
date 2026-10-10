import SwiftUI
import SwiftData

struct ForYouView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var library: Library
    @StateObject private var recommendations = Recommendations.shared
    @Query(filter: #Predicate<Article> { $0.originRaw == 1 }, sort: \Article.createdAt, order: .reverse)
    private var picks: [Article]

    private var grouped: [(day: Date, items: [Article])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: picks) { calendar.startOfDay(for: $0.recommendedAt ?? $0.createdAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $router.forYouPath) {
            List {
                ForEach(grouped, id: \.day) { group in
                    Section {
                        ForEach(group.items) { article in
                            NavigationLink(value: article.id) {
                                ArticleRow(article: article, showReason: true)
                            }
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 16))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    if let url = article.url { withAnimation { _ = library.save(url: url) } }
                                } label: { Label("Save", systemImage: "plus") }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation { recommendations.dismiss(article) }
                                } label: { Label("Not for me", systemImage: "hand.thumbsdown") }
                            }
                        }
                    } header: {
                        Text(dayTitle(group.day))
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if picks.isEmpty {
                    ContentUnavailableView {
                        Label("Your picks are on the way", systemImage: "sparkles")
                    } description: {
                        Text(recommendations.failed
                             ? "Couldn't check for new picks. Pull down to try again."
                             : "Each morning Claude picks a handful of articles for you on AI, business, venture capital and consumer investing.")
                    }
                }
            }
            .navigationTitle("For You")
            .refreshable { await recommendations.refresh(force: true) }
            .navigationDestination(for: UUID.self) { id in
                ReaderContainer(id: id)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
