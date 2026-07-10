import Foundation

/// A single item handed to Readymade through the iOS share sheet, normalized to
/// the small envelope the web app consumes at a board's pipeline head. Kept
/// deliberately generic (`url` / `title` / `text` are all optional) so richer
/// content types — images, files — can be added later without changing the
/// contract with the web side.
struct SharedItem: Codable {
    let id: String
    /// Seconds since the Unix epoch, so both native and JS parse it trivially.
    let receivedAt: Double
    let url: String?
    let title: String?
    let text: String?
    /// Board chosen in the share extension's picker. When set, the web app
    /// skips its in-app picker and runs this board directly; when nil the
    /// in-app picker asks (fallback for stale envelopes / empty board mirror).
    let boardName: String?

    init(url: String?, title: String?, text: String?, boardName: String? = nil) {
        self.id = UUID().uuidString
        self.receivedAt = Date().timeIntervalSince1970
        self.url = url
        self.title = title
        self.text = text
        self.boardName = boardName
    }
}

/// A tiny file-backed drop box in the App Group container shared between the
/// host app and the share extension. The extension (a separate process) writes
/// one JSON file per shared item here; the host app drains it once it comes to
/// the foreground and forwards each item into the web app.
///
/// The App Group is the only channel the two processes share — the extension
/// cannot reach the app's WebView or its `localStorage` directly.
enum ShareInbox {
    /// Must match the App Group capability enabled on BOTH the app and the
    /// extension targets (see the two `.entitlements` files). Keep in sync.
    static let appGroupID = "group.com.readymadeit.app-ios"

    /// Directory holding one `<id>.json` per pending shared item. `nil` only if
    /// the App Group entitlement is missing/misconfigured, which we treat as a
    /// hard configuration error at the call sites.
    static func inboxURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return container.appendingPathComponent("SharedInbox", isDirectory: true)
    }

    /// Persist a shared item and return its id (used as the `?id=` deep-link
    /// query so the app can drain that specific item first).
    @discardableResult
    static func write(_ item: SharedItem) throws -> String {
        guard let inbox = inboxURL() else {
            throw ShareInboxError.missingAppGroup
        }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(item)
        try data.write(to: inbox.appendingPathComponent("\(item.id).json"), options: .atomic)
        return item.id
    }

    /// All pending items, oldest first. Used on cold start when the deep-link id
    /// alone might miss items queued while the app was not running.
    static func pending() -> [SharedItem] {
        guard let inbox = inboxURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SharedItem? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SharedItem.self, from: data)
            }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Remove an item once it has been handed to the web app, so it is consumed
    /// exactly once.
    static func remove(id: String) {
        guard let inbox = inboxURL() else { return }
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(id).json"))
    }

    // ── Boards mirror ─────────────────────────────────────────────────────────
    // The board list lives in the web app's localStorage, which the share
    // extension cannot read. The app mirrors the board *names* into the App
    // Group whenever they change, so the extension can offer a native picker
    // (the WhatsApp pattern: the whole action happens inside the extension).

    private static func boardsMirrorURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return container.appendingPathComponent("boards-mirror.json")
    }

    /// Called by the host app (via the hkpShareBoards message handler) whenever
    /// the web app reports its current board list.
    static func writeBoardsMirror(_ names: [String]) {
        guard let url = boardsMirrorURL(),
              let data = try? JSONEncoder().encode(names) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Board names as of the app's last sync; empty if the app never ran or
    /// the user has no boards yet.
    static func readBoardsMirror() -> [String] {
        guard let url = boardsMirrorURL(),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names
    }
}

enum ShareInboxError: LocalizedError {
    case missingAppGroup

    var errorDescription: String? {
        switch self {
        case .missingAppGroup:
            return "App Group container is unavailable (entitlement missing?)"
        }
    }
}
