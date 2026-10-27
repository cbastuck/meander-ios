import Foundation

/// A single item handed to Readymade through the iOS share sheet, normalized to
/// the small envelope the web app consumes at a board's pipeline head. Kept
/// deliberately generic (`url` / `title` / `text` are all optional) so richer
/// content types — images, files — can be added later without changing the
/// contract with the web side.
/// Metadata for a binary payload (image, PDF, any file) that accompanies a
/// shared item. The bytes themselves are never part of the JSON envelope —
/// they live as `<id>.payload` next to it and are served to the web app on
/// demand through the hkp://share-files/<id> route.
struct SharedFile: Codable {
    let name: String
    let mimeType: String
    let size: Int
}

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
    /// Present when the share carries a binary payload (image/file).
    let file: SharedFile?

    init(
        url: String?,
        title: String?,
        text: String?,
        boardName: String? = nil,
        file: SharedFile? = nil
    ) {
        self.id = UUID().uuidString
        self.receivedAt = Date().timeIntervalSince1970
        self.url = url
        self.title = title
        self.text = text
        self.boardName = boardName
        self.file = file
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
    /// extension targets (see the `.entitlements` files). Keep in sync. This
    /// file is compiled into the iOS app + extension AND the macOS share
    /// extension (meander/macos/ShareExtension), whose host app reads the
    /// inbox through backend/shareInbox.{h,mm}.
    #if os(macOS)
    static let appGroupID = "group.com.readymadeit.app"
    #else
    static let appGroupID = "group.com.readymadeit.app-ios"
    #endif

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
    /// exactly once. The binary payload (if any) is NOT removed here — the web
    /// app fetches it lazily and releases it via removeFilePayload once the
    /// board has consumed it.
    static func remove(id: String) {
        guard let inbox = inboxURL() else { return }
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(id).json"))
    }

    // ── Binary payloads ───────────────────────────────────────────────────────

    /// Refuse payloads beyond this size: everything downstream (scheme-handler
    /// read, webview fetch, pipeline injection) holds the bytes in memory.
    static let maxFilePayloadBytes = 100 * 1024 * 1024

    static func filePayloadURL(id: String) -> URL? {
        inboxURL()?.appendingPathComponent("\(id).payload")
    }

    /// Copies a staged file into the App Group as the payload of item `id`
    /// (file-to-file copy — the bytes are never loaded into memory here).
    static func storeFilePayload(from stagedURL: URL, id: String) throws {
        guard let inbox = inboxURL(), let target = filePayloadURL(id: id) else {
            throw ShareInboxError.missingAppGroup
        }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: stagedURL, to: target)
    }

    static func readFilePayload(id: String) -> Data? {
        guard let url = filePayloadURL(id: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func removeFilePayload(id: String) {
        guard let url = filePayloadURL(id: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes payloads that were never consumed (e.g. the user cancelled the
    /// in-app picker, so nothing ever fetched + released the bytes). Called on
    /// each inbox drain; anything older than a week is safe to drop.
    static func sweepStalePayloads(olderThan age: TimeInterval = 7 * 24 * 3600) {
        guard let inbox = inboxURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date(timeIntervalSinceNow: -age)
        for url in urls where url.pathExtension == "payload" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // ── Boards mirror ─────────────────────────────────────────────────────────
    // The board library (BoardLibrary.swift) may be in iCloud Drive, which the
    // share extension and the widget have no access to. The library writes the
    // board *names* into the App Group whenever they change, so the extension
    // can offer a native picker (the WhatsApp pattern: the whole action happens
    // inside the extension) and the Open Board intent can list them.

    private static func boardsMirrorURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return container.appendingPathComponent("boards-mirror.json")
    }

    /// Called by the board library whenever its boards change.
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
