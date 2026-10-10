import WidgetKit
import SwiftUI

struct ShelfEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ShelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShelfEntry {
        ShelfEntry(date: .now, snapshot: WidgetSnapshot(
            unreadCount: 12,
            next: .init(id: UUID(), title: "Your next saved article appears here", source: "Shelf", minutes: 6),
            updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : ShelfEntry(date: .now, snapshot: SnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
        let entry = ShelfEntry(date: .now, snapshot: SnapshotStore.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct ShelfWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShelfEntry

    private var count: Int { entry.snapshot.unreadCount }
    private var next: WidgetSnapshot.Next? { entry.snapshot.next }

    private var link: URL {
        if let next { return URL(string: "shelf://open/\(next.id.uuidString)")! }
        return URL(string: "shelf://next")!
    }

    var body: some View {
        content
            .widgetURL(link)
            .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                Text("SHELF")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(count == 1 ? "waiting to read" : "waiting to read")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .systemMedium:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("UP NEXT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("\(count) to read")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let next {
                    Text(next.title)
                        .font(.headline)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Text([next.source, next.minutes.map { "\($0) min read" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Spacer()
                    Text("All caught up")
                        .font(.headline)
                    Text("Tap Share, then Shelf, in any app to save something.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "books.vertical.fill").font(.caption2)
                    Text("\(count)").font(.system(.title3, design: .rounded).weight(.bold))
                }
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Up next · \(count)", systemImage: "books.vertical.fill")
                    .font(.caption.weight(.semibold))
                Text(next?.title ?? "All caught up")
                    .font(.caption)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .accessoryInline:
            Label(count == 0 ? "All read" : "\(count) to read", systemImage: "books.vertical")

        default:
            Text("\(count)")
        }
    }
}

struct ShelfWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShelfWidget", provider: ShelfProvider()) { entry in
            ShelfWidgetView(entry: entry)
        }
        .configurationDisplayName("Shelf")
        .description("See what's waiting to read, and jump straight in.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ShelfWidgets: WidgetBundle {
    var body: some Widget {
        ShelfWidget()
    }
}
