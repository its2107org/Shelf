import Foundation
import SwiftUI

/// Which tab is showing and which article is open, so widgets, Siri and Spotlight can jump straight in.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    enum Tab: Hashable { case saved, forYou }

    @Published var tab: Tab = .saved
    @Published var savedPath: [UUID] = []
    @Published var forYouPath: [UUID] = []
    @Published var showSettings = ProcessInfo.processInfo.arguments.contains("-ShelfDemoSettings")

    func open(_ id: UUID) {
        guard let article = Library.shared.article(id: id) else { return }
        if article.origin == .recommended {
            tab = .forYou
            forYouPath = [id]
        } else {
            tab = .saved
            savedPath = [id]
        }
    }

    func openNextUnread() {
        if let next = SnapshotStore.read().next {
            open(next.id)
        } else {
            tab = .saved
            savedPath = []
        }
    }

    /// shelf://open/<id>, shelf://next
    func handle(_ url: URL) {
        guard url.scheme == "shelf" else { return }
        switch url.host {
        case "open":
            if let id = UUID(uuidString: url.lastPathComponent) { open(id) }
        case "next":
            openNextUnread()
        case "settings":
            // shelf://settings opens the logins screen (handy as a link in messages).
            tab = .saved
            showSettings = true
        default:
            break
        }
    }
}

/// Reading preferences, remembered between articles.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case automatic, light, sepia, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light, .sepia: return .light
        case .dark: return .dark
        }
    }

    var background: Color? {
        switch self {
        case .sepia: return Color(red: 0.973, green: 0.945, blue: 0.890)
        case .dark: return .black
        default: return nil
        }
    }

    var text: Color? {
        switch self {
        case .sepia: return Color(red: 0.231, green: 0.184, blue: 0.118)
        default: return nil
        }
    }
}
