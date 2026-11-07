import AppIntents
import SwiftUI
import WidgetKit

/// The Readymade widget: one board on the Home Screen, opened with a tap. It is
/// the closest iOS comes to a board of its own there, since an app cannot place
/// an icon itself.
///
/// It runs in its own process and reads the pinned list from the App Group
/// (`HomeScreenPins`). Until the person picks a board, it shows the one pinned
/// last — so adding the widget right after pinning shows that board.
@main
struct ReadymadeWidgets: WidgetBundle {
    var body: some Widget {
        BoardWidget()
    }
}

struct SelectBoardIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Board"
    static var description = IntentDescription("The board the widget opens.")

    @Parameter(title: "Board")
    var board: BoardEntity?
}

struct BoardWidgetEntry: TimelineEntry {
    let date: Date
    let board: BoardEntity?
}

struct BoardWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BoardWidgetEntry {
        BoardWidgetEntry(
            date: Date(),
            board: BoardEntity(kind: "saved", boardId: "", title: "My board")
        )
    }

    func snapshot(for configuration: SelectBoardIntent, in context: Context) async -> BoardWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectBoardIntent, in context: Context) async -> Timeline<BoardWidgetEntry> {
        // Nothing here changes with time; the app reloads the widgets when the
        // pinned list does.
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SelectBoardIntent) -> BoardWidgetEntry {
        BoardWidgetEntry(
            date: Date(),
            board: configuration.board ?? HomeScreenPins.list().first.map(BoardEntity.init(pin:))
        )
    }
}

struct BoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "BoardWidget",
            intent: SelectBoardIntent.self,
            provider: BoardWidgetProvider()
        ) { entry in
            BoardWidgetView(entry: entry)
        }
        .configurationDisplayName("Board")
        .description("Opens a Readymade board.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BoardWidgetView: View {
    let entry: BoardWidgetEntry

    var body: some View {
        if let board = entry.board {
            content(title: board.title, caption: board.kind == "demo" ? "Demo" : "Readymade")
                .widgetURL(board.launchURL)
                .containerBackground(for: .widget) { tint(for: board.title) }
        } else {
            // Nothing pinned yet: a tap opens the app, where boards are pinned.
            content(title: "Pin a board", caption: "in Readymade")
                .containerBackground(for: .widget) { tint(for: "") }
        }
    }

    private func content(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(3)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// A colour of the board's own, stable across launches: the same name
    /// always gets the same one, so two widgets side by side tell apart.
    private func tint(for title: String) -> LinearGradient {
        let hue = Double(title.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.62),
                Color(hue: hue, saturation: 0.65, brightness: 0.42),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
