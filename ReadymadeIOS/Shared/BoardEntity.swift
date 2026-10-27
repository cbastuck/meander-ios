import AppIntents
import Foundation

/// A board as Shortcuts, Siri, Spotlight and the widget's configuration see
/// it. Pinned boards come first, then the saved boards the app last mirrored
/// into the App Group (`ShareInbox.readBoardsMirror`). A demo is offered only
/// once it is pinned: the demos are the web app's, and pinning is where one
/// gets a name the native side knows.
///
/// Compiled into the app (the Open Board intent) and the widget extension (its
/// configuration); each gets its own copy of the type.
struct BoardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Board"
    static var defaultQuery = BoardQuery()

    /// "saved:<name>" or "demo:<slug>".
    let id: String
    let kind: String
    let boardId: String
    let title: String

    init(kind: String, boardId: String, title: String) {
        self.id = "\(kind):\(boardId)"
        self.kind = kind
        self.boardId = boardId
        self.title = title
    }

    init(pin: HomeScreenPin) {
        self.init(kind: pin.kind, boardId: pin.id, title: pin.title)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: kind == "demo" ? "Demo" : nil
        )
    }

    var launchURL: URL {
        HomeScreenPins.launchURL(kind: kind, id: boardId)
    }
}

struct BoardQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BoardEntity] {
        let known = Self.all()
        return identifiers.compactMap { id in known.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [BoardEntity] {
        Self.all().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [BoardEntity] {
        Self.all()
    }

    /// Pinned boards, newest first, then the other saved boards by name.
    static func all() -> [BoardEntity] {
        let pinned = HomeScreenPins.list().map(BoardEntity.init(pin:))
        let saved = ShareInbox.readBoardsMirror()
            .filter { name in !pinned.contains { $0.kind == "saved" && $0.boardId == name } }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { BoardEntity(kind: "saved", boardId: $0, title: $0) }
        return pinned + saved
    }
}
