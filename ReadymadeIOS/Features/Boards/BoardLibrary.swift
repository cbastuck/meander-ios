import Foundation

/// A board's name as it names the board's file — the desktop's rule
/// (`meander/backend/boardName.h`), so a folder both apps read names a board
/// the same way on both: ASCII letters, digits, `-`, `_` and spaces as they
/// are, every other UTF-8 byte as `%XX`. No separator and no dot survives, so
/// any name is one path component.
enum BoardFileName {
    static let fileExtension = "hkpp"

    static func encode(_ name: String) -> String {
        var encoded = ""
        for byte in name.utf8 {
            let kept = (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F || byte == 0x20
            if kept {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func decode(_ storageName: String) -> String {
        let bytes = Array(storageName.utf8)
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
               let byte = UInt8(String(bytes: bytes[index + 1...index + 2], encoding: .ascii) ?? "", radix: 16) {
                decoded.append(byte)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// The desktop's rule for which names are accepted: non-empty and free of
    /// control characters. Everything else is the encoding's job.
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

enum BoardLibraryError: LocalizedError {
    case invalidBoardName
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidBoardName:
            return "Invalid board name"
        case .notFound(let name):
            return "No board called “\(name)”"
        }
    }
}

/// The saved boards: `<encoded name>.hkpp` files in the app's iCloud Drive
/// container when iCloud Drive is on — where the Files app and Finder on the
/// person's Mac show them, under "Readymade" — and in the app's own Documents
/// otherwise, which the Files app shows under "On My iPhone".
///
/// Everything runs on one serial queue. The first thing on it is `prepare`,
/// which resolves the container (a call Apple says not to make on the main
/// thread) and brings older boards along, so no request can see the library
/// half-prepared. Reads and writes in the container are coordinated, which is
/// also what downloads a board iCloud has not brought to this device yet.
final class BoardLibrary {
    static let shared = BoardLibrary()

    static let iCloudContainerID = "iCloud.com.readymadeit.readymade"

    let queue = DispatchQueue(label: "com.readymadeit.boards")
    private let fileManager = FileManager.default
    private var root: URL?
    private(set) var isInICloud = false

    private init() {}

    /// The local Documents/Boards: the library without iCloud, and where boards
    /// written before this version are.
    private var localRoot: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boards", isDirectory: true)
    }

    /// Resolves where the library is and moves older boards into it. Called at
    /// launch; everything else waits behind it on the queue.
    func prepare() {
        queue.async { self.resolveRoot() }
    }

    private func resolveRoot() {
        if fileManager.ubiquityIdentityToken != nil,
           let container = fileManager.url(forUbiquityContainerIdentifier: Self.iCloudContainerID) {
            root = container.appendingPathComponent("Documents/Boards", isDirectory: true)
            isInICloud = true
        } else {
            root = localRoot
            isInICloud = false
        }
        try? fileManager.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        renameLegacyBoards()
        if isInICloud {
            adoptLocalBoards()
        }
        writeMirror()
        NSLog("Readymade boards live in %@ (%@)", currentRoot.path, isInICloud ? "iCloud" : "local")
    }

    private var currentRoot: URL {
        root ?? localRoot
    }

    // ── Bringing older boards along ──────────────────────────────────────────

    /// Before this version boards were `<name>.json`, named as typed. Each
    /// becomes `<encoded>.hkpp` in the library, under a free name if the
    /// library has one by that name already.
    private func renameLegacyBoards() {
        guard let files = try? fileManager.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            guard BoardFileName.isValid(name), let data = try? Data(contentsOf: file) else {
                continue
            }
            do {
                try write(data, to: fileURL(for: freeName(name)))
                try fileManager.removeItem(at: file)
            } catch {
                NSLog("Readymade could not move board %@: %@", name, error.localizedDescription)
            }
        }
    }

    /// Boards kept on this device while iCloud Drive was off move into the
    /// container once it is on, so a board is never in a place the person no
    /// longer sees.
    private func adoptLocalBoards() {
        guard let files = try? fileManager.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == BoardFileName.fileExtension {
            let name = BoardFileName.decode(file.deletingPathExtension().lastPathComponent)
            do {
                try fileManager.setUbiquitous(true, itemAt: file, destinationURL: fileURL(for: freeName(name)))
            } catch {
                NSLog("Readymade could not move board %@ to iCloud: %@", name, error.localizedDescription)
            }
        }
    }

    /// `name`, or `name (2)`, `name (3)`… — the first the library has no board by.
    private func freeName(_ name: String) -> String {
        var candidate = name
        var counter = 2
        while exists(candidate) {
            candidate = "\(name) (\(counter))"
            counter += 1
        }
        return candidate
    }

    // ── The library ──────────────────────────────────────────────────────────
    // Called on `queue`.

    struct Entry {
        let name: String
        /// Last write, ISO 8601 UTC; empty for a board iCloud has not brought
        /// to this device yet.
        let modified: String
    }

    func list() -> [Entry] {
        let formatter = ISO8601DateFormatter()
        guard let files = try? fileManager.contentsOfDirectory(
            at: currentRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return []
        }

        var entries: [String: Entry] = [:]
        for file in files {
            var fileName = file.lastPathComponent
            // A board iCloud knows of but has not downloaded is a hidden
            // placeholder, ".<file>.icloud". It is listed all the same, and
            // asked for, so it is there by the time it is opened.
            if fileName.hasPrefix("."), fileName.hasSuffix(".icloud") {
                fileName = String(fileName.dropFirst().dropLast(".icloud".count))
                try? fileManager.startDownloadingUbiquitousItem(at: currentRoot.appendingPathComponent(fileName))
            } else if fileName.hasPrefix(".") {
                continue
            }
            let stem = (fileName as NSString).deletingPathExtension
            guard (fileName as NSString).pathExtension == BoardFileName.fileExtension else {
                continue
            }
            let name = BoardFileName.decode(stem)
            let modified = (try? currentRoot.appendingPathComponent(fileName)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            entries[name] = Entry(name: name, modified: modified.map(formatter.string(from:)) ?? "")
        }
        return entries.values.sorted { $0.name < $1.name }
    }

    func load(_ name: String) throws -> Data {
        let url = try fileURL(for: validated(name))
        guard exists(name) else {
            throw BoardLibraryError.notFound(name)
        }
        return try coordinated(reading: url)
    }

    func save(_ data: Data, as name: String) throws {
        try write(data, to: fileURL(for: validated(name)))
        writeMirror()
    }

    func delete(_ name: String) throws {
        let url = try fileURL(for: validated(name))
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
            } catch {
                removeError = error
            }
        }
        if let error = coordinationError ?? removeError {
            throw error
        }
        writeMirror()
    }

    private func exists(_ name: String) -> Bool {
        let file = BoardFileName.encode(name) + "." + BoardFileName.fileExtension
        return fileManager.fileExists(atPath: currentRoot.appendingPathComponent(file).path)
            || fileManager.fileExists(atPath: currentRoot.appendingPathComponent(".\(file).icloud").path)
    }

    private func validated(_ name: String) throws -> String {
        guard BoardFileName.isValid(name) else {
            throw BoardLibraryError.invalidBoardName
        }
        return name
    }

    private func fileURL(for name: String) -> URL {
        currentRoot.appendingPathComponent(BoardFileName.encode(name) + "." + BoardFileName.fileExtension)
    }

    private func coordinated(reading url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(BoardLibraryError.notFound(url.lastPathComponent))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try result.get()
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError {
            throw error
        }
    }

    /// The board names, for the share extension's picker and the Open Board
    /// intent, which run in other processes and cannot reach the library.
    private func writeMirror() {
        ShareInbox.writeBoardsMirror(list().map(\.name))
    }
}

/// A board's history: the snapshots taken as it was edited, newest first, kept
/// on this device only. History is rewritten at every pause in editing, which
/// is no traffic for iCloud and a conflict waiting to happen between two
/// devices. The desktop's rules (`handlePushBoardSnapshot` in
/// `meander/backend/schemeHandler.cpp`): at most 50 entries, and consecutive
/// "config" entries replace each other.
final class BoardHistoryStore {
    static let maxDepth = 50

    private let fileManager = FileManager.default

    private var directory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("History", isDirectory: true)
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(BoardFileName.encode(name) + ".history")
    }

    /// Every board with a history, and when it was last written.
    func summaries() -> [[String: String]] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "history" }.map { file in
            var summary = ["name": BoardFileName.decode(file.deletingPathExtension().lastPathComponent)]
            if let latest = entries(at: file).first?["timestamp"] as? String {
                summary["latestTimestamp"] = latest
            }
            return summary
        }
    }

    func load(_ name: String) -> Data {
        (try? Data(contentsOf: fileURL(for: name))) ?? Data("[]".utf8)
    }

    func push(_ body: Data, for name: String) throws {
        guard var entry = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BoardLibraryError.invalidBoardName
        }
        // The registry is the runtimes' to say again on load; keeping it
        // would multiply every snapshot by every service's description.
        if var snapshot = entry["snapshot"] as? [String: Any] {
            snapshot.removeValue(forKey: "registry")
            entry["snapshot"] = snapshot
        }

        let url = fileURL(for: name)
        var history = entries(at: url)
        let isConfig: ([String: Any]) -> Bool = { ($0["label"] as? String) == "config" }
        if isConfig(entry), let latest = history.first, isConfig(latest) {
            history[0] = entry
        } else {
            history.insert(entry, at: 0)
        }
        history = Array(history.prefix(Self.maxDepth))

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: history).write(to: url, options: .atomic)
    }

    func clear(_ name: String) {
        try? fileManager.removeItem(at: fileURL(for: name))
    }

    private func entries(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return history
    }
}

/// The board finder's folder tree, kept on this device: it names boards, and
/// which boards there are differs between a phone and a Mac sharing some.
final class StartPageTreeStore {
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("startpage.json")
    }

    func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
