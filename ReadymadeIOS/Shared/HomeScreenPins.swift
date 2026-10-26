import Foundation

/// A board pinned to the Home Screen: a saved board by its name, a demo by its
/// slug — the two kinds of board whose identity outlives a session. `title` is
/// what iOS shows for it (quick action, widget, Shortcuts).
struct HomeScreenPin: Codable, Equatable {
    let kind: String
    let id: String
    let title: String

    static let kinds: Set<String> = ["saved", "demo"]

    func isSame(kind: String, id: String) -> Bool {
        self.kind == kind && self.id == id
    }

    /// What opens this board: readymade://board?saved=<name> or ?demo=<slug>.
    var launchURL: URL {
        HomeScreenPins.launchURL(kind: kind, id: id)
    }
}

/// The pinned list, kept in the App Group so everything that launches a board
/// reads the same one: the app (quick actions, the Open Board intent) and the
/// widget extension, which runs in its own process. Newest first, so "the board
/// pinned last" — what a freshly added widget opens — is the first entry.
///
/// Compiled into the app and the widget extension.
enum HomeScreenPins {
    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.appGroupID)?
            .appendingPathComponent("home-screen-pins.json")
    }

    static func list() -> [HomeScreenPin] {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode([HomeScreenPin].self, from: data) else {
            return []
        }
        return pins.filter { HomeScreenPin.kinds.contains($0.kind) }
    }

    /// Pins `pin`, or renames it when it is pinned already; either way it moves
    /// to the front.
    @discardableResult
    static func add(_ pin: HomeScreenPin) throws -> [HomeScreenPin] {
        guard HomeScreenPin.kinds.contains(pin.kind), !pin.id.isEmpty else {
            throw HomeScreenPinsError.invalidPin
        }
        let pins = [pin] + list().filter { !$0.isSame(kind: pin.kind, id: pin.id) }
        try write(pins)
        return pins
    }

    @discardableResult
    static func remove(kind: String, id: String) throws -> [HomeScreenPin] {
        let pins = list().filter { !$0.isSame(kind: kind, id: id) }
        try write(pins)
        return pins
    }

    private static func write(_ pins: [HomeScreenPin]) throws {
        guard let url = fileURL() else {
            throw ShareInboxError.missingAppGroup
        }
        try JSONEncoder().encode(pins).write(to: url, options: .atomic)
    }

    // ── The launch link ───────────────────────────────────────────────────────
    // One URL for every way in — widget, quick action, intent — so the app has a
    // single place where a launch arrives (`onOpenURL`, or LaunchRouter
    // directly from inside the app's own process).

    static func launchURL(kind: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = "readymade"
        components.host = "board"
        components.queryItems = [URLQueryItem(name: kind, value: id)]
        return components.url!
    }

    /// The board a launch link names, or nil for any other link.
    static func target(from url: URL) -> (kind: String, id: String)? {
        guard url.scheme?.lowercased() == "readymade", url.host == "board",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for item in items where HomeScreenPin.kinds.contains(item.name) {
            if let id = item.value, !id.isEmpty {
                return (item.name, id)
            }
        }
        return nil
    }
}

enum HomeScreenPinsError: LocalizedError {
    case invalidPin

    var errorDescription: String? {
        switch self {
        case .invalidPin:
            return "Only a saved board or a demo can be pinned"
        }
    }
}
