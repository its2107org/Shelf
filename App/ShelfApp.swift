import SwiftUI
import SwiftData
import CoreSpotlight
import BackgroundTasks

@main
struct ShelfApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = Router.shared
    @StateObject private var library = Library.shared

    nonisolated private static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "shelf") + ".refresh"

    init() {
        Extractor.browser = { url, script in await BrowserReader.shared.read(url, script: script) }
        Demo.seedIfRequested()
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .environmentObject(library)
                .onOpenURL { router.handle($0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:)) {
                        router.open(id)
                    }
                }
        }
        .modelContainer(library.container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    if !SubscribedSites.all.isEmpty { await SignInWebView.shareCookies() }
                    await library.sync()
                    await Recommendations.shared.refresh()
                    await library.processPending()
                }
            case .background:
                Self.scheduleRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            Self.scheduleRefresh()
            await Library.shared.sync()
            await Recommendations.shared.refresh(force: true)
            await Library.shared.processPending()
        }
    }

    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
