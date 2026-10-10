import SwiftUI

struct RootView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            SavedView()
                .tabItem { Label("Saved", systemImage: "books.vertical") }
                .tag(Router.Tab.saved)
            ForYouView()
                .tabItem { Label("For You", systemImage: "sparkles") }
                .tag(Router.Tab.forYou)
        }
    }
}
