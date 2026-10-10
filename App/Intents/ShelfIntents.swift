import AppIntents
import Foundation

struct OpenNextArticleIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Next Article"
    static var description = IntentDescription("Opens the most recent article you haven't read yet.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Library.shared.importInbox()
        Router.shared.openNextUnread()
        return .result()
    }
}

struct SaveLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Save to Shelf"
    static var description = IntentDescription("Saves a link to read later.")

    @Parameter(title: "Link")
    var link: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$link) to Shelf")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let article = Library.shared.save(url: link)
        await Library.shared.prepare(article)
        return .result(dialog: "Saved \"\(article.title)\" to Shelf.")
    }
}

struct UnreadCountIntent: AppIntent {
    static var title: LocalizedStringResource = "How Many to Read"
    static var description = IntentDescription("Tells you how many saved articles are waiting.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        Library.shared.importInbox()
        let count = SnapshotStore.read().unreadCount
        let dialog: IntentDialog = count == 0
            ? "You're all caught up."
            : (count == 1 ? "You have 1 article to read." : "You have \(count) articles to read.")
        return .result(value: count, dialog: dialog)
    }
}

struct ShelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNextArticleIntent(),
            phrases: [
                "Open my next article in \(.applicationName)",
                "Read next in \(.applicationName)",
                "Open \(.applicationName) reading"
            ],
            shortTitle: "Next Article",
            systemImageName: "book"
        )
        AppShortcut(
            intent: UnreadCountIntent(),
            phrases: [
                "How many articles are in \(.applicationName)",
                "What's waiting in \(.applicationName)"
            ],
            shortTitle: "How Many to Read",
            systemImageName: "number"
        )
        AppShortcut(
            intent: SaveLinkIntent(),
            phrases: ["Save to \(.applicationName)"],
            shortTitle: "Save Link",
            systemImageName: "plus"
        )
    }
}
