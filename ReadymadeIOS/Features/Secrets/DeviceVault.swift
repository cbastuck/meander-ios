import Foundation
import Security
import WebKit

/// The values behind the aliases a board refers to (`{{secret.<alias>}}`), in
/// the Keychain.
///
/// The phone's counterpart of the desktop's `~/.hkp/vault.json`
/// (`meander/backend/vault.h`), with the same entry: a value and the hosts it
/// may be sent to. One generic-password item per alias, holding
/// `{ "value": "…", "audience": ["imap.gmail.com"] }`. An empty audience is
/// unconstrained.
///
/// Kept on this device only (`…ThisDeviceOnly`): never in iCloud Keychain, and
/// not restored onto another phone from a backup. Each provisioner keeps its
/// own vault and the alias is the interface between them (plans/TODO-SECRETS.md,
/// Prio B), so nothing syncs a secret behind the person's back. Readable after
/// the first unlock, because a board runs whenever the app does.
final class DeviceVault {
    static let shared = DeviceVault()

    struct Entry {
        var value: String
        var audience: [String]
    }

    private let service = "com.readymadeit.readymade.secrets"

    /// The names held, without the values.
    func aliases() -> [String] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func entry(_ alias: String) -> Entry? {
        var query = baseQuery(alias)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = object["value"] as? String else {
            return nil
        }
        let audience = (object["audience"] as? [String] ?? []).filter { !$0.isEmpty }
        return Entry(value: value, audience: audience)
    }

    /// Every entry, for injecting into the app's page.
    func all() -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for alias in aliases() {
            entries[alias] = entry(alias)
        }
        return entries
    }

    /// Sets the value, leaving the audience the entry already had.
    func setValue(_ value: String, for alias: String) throws {
        try write(Entry(value: value, audience: entry(alias)?.audience ?? []), for: alias)
    }

    /// Sets where an entry may be sent, leaving its value alone. False when
    /// there is no such entry: an audience constrains a value, and with none
    /// there is nothing to constrain.
    func setAudience(_ audience: [String], for alias: String) throws -> Bool {
        guard let held = entry(alias) else {
            return false
        }
        try write(Entry(value: held.value, audience: audience.filter { !$0.isEmpty }), for: alias)
        return true
    }

    func delete(_ alias: String) -> Bool {
        SecItemDelete(baseQuery(alias) as CFDictionary) == errSecSuccess
    }

    private func write(_ entry: Entry, for alias: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["value": entry.value, "audience": entry.audience])
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(baseQuery(alias) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else {
            throw DeviceVaultError.keychain(updated)
        }
        let added = SecItemAdd(
            baseQuery(alias).merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw DeviceVaultError.keychain(added)
        }
    }

    private func baseQuery(_ alias: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let alias {
            query[kSecAttrAccount as String] = alias
        }
        return query
    }
}

enum DeviceVaultError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain refused the secret: \(message)"
        }
    }
}

/// Which board may hand which secrets to which runtime: the remembered answers
/// to the consent prompt, keyed as `hkp-frontend/src/core/secretConsent.ts`
/// says. The desktop keeps them in `~/.hkp/grants.json`
/// (`meander/backend/grants.h`); here they are a file in Application Support,
/// which only this app can write. Grants hold no secrets, they name them, so
/// they are not in the Keychain.
final class SecretGrants {
    static let shared = SecretGrants()

    private let fileManager = FileManager.default

    private var fileURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("grants.json")
    }

    func all() -> [String: [String]] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var grants: [String: [String]] = [:]
        for (key, value) in object {
            let aliases = (value as? [String] ?? []).filter { !$0.isEmpty }
            if !aliases.isEmpty {
                grants[key] = aliases
            }
        }
        return grants
    }

    /// Adds aliases to a grant, leaving the rest of it alone: a board that
    /// comes to need one more secret is asked about that one, and the answer
    /// must not drop what was already agreed.
    func grant(_ aliases: [String], under key: String) throws {
        var grants = all()
        let merged = Set((grants[key] ?? []) + aliases.filter { !$0.isEmpty })
        guard !merged.isEmpty else {
            return
        }
        grants[key] = merged.sorted()
        try write(grants)
    }

    /// Forgets one grant entirely, so the next release asks again.
    func revoke(_ key: String) throws {
        var grants = all()
        guard grants.removeValue(forKey: key) != nil else {
            return
        }
        try write(grants)
    }

    private func write(_ grants: [String: [String]]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: grants, options: [.sortedKeys])
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// What the app's page is told about secrets at creation, and how a request to
/// `hkp://secrets` proves it came from that page.
///
/// The page reads the vault and the grants before any board loads, as on the
/// desktop: provisioning starts as soon as a board does, and a value or a grant
/// that arrived a moment later would leave a credential unset or ask a question
/// already answered. The script is given only to the app's own pages, read
/// from protocol and host rather than `location.origin`, which a custom scheme
/// may state as "null".
///
/// The route answers only requests carrying `token`, which is handed out the
/// same way. Every other `hkp://` route answers any origin; this one must not,
/// because a frame inside the page — a service's own UI, an embedded site —
/// shares the scheme with the app and must not be able to list, replace or
/// constrain what is held.
enum SecretsPage {
    static let tokenHeader = "X-Hkp-Secrets-Token"

    /// Drawn once per launch: anything that can read it can already read every
    /// value, because both are given to the same page.
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Origins (`protocol//host`) of the pages that are the app.
    static var ownPages: [String] = ["hkp://app"]

    private static var installed: WKUserScript?

    /// Gives the page the vault as it is now, replacing what an earlier call
    /// gave it. Called at creation and after every change: the script runs on
    /// each load, and iOS reloads a page whose content process it reclaimed, so
    /// a script written once at launch would bring back a deleted secret and
    /// lose one added since.
    static func install(into controller: WKUserContentController) {
        let others = controller.userScripts.filter { $0 !== installed }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
        let script = WKUserScript(source: source(), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(script)
        installed = script
    }

    private static func source() -> String {
        let vault = DeviceVault.shared.all().mapValues { entry -> [String: Any] in
            ["value": entry.value, "audience": entry.audience]
        }
        let code = """
        window.__HKP_VAULT__ = \(json(vault));
        window.__HKP_GRANTS__ = \(json(SecretGrants.shared.all()));
        window.__HKP_SECRETS_TOKEN__ = \(json(token));
        """
        return "if (\(json(ownPages)).includes(location.protocol + '//' + location.host)) { \(code) }"
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}
