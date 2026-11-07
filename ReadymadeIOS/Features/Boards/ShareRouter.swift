import Foundation
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import WebKit

/// Bridges a captured share from the native side into the web app.
///
/// The share extension writes envelopes to the App Group inbox and opens
/// `readymade://share`. That URL arrives at the SwiftUI scene, while the
/// WKWebView that actually runs the boards lives inside `BoardListView`. This
/// singleton is the seam between them: the web view registers here, the scene
/// forwards the open-URL, and pending inbox items are pushed into the page.
///
/// Delivery is inbox-driven rather than URL-driven so cold start is handled for
/// free — whether the app was already running (open-URL triggers a drain) or
/// launched by the share (the drain runs once the page finishes loading), the
/// same `pending()` files get delivered exactly once.
final class ShareRouter {
    static let shared = ShareRouter()
    private init() {}

    private weak var webView: WKWebView?
    private var webAppReady = false

    /// Called by `BoardListView` when the web view is created.
    func register(webView: WKWebView) {
        self.webView = webView
    }

    /// Called on the first successful navigation, when `__readymadeDeliverShare`
    /// (injected at document start) and the React consumer are in place.
    func webAppDidFinishLoading() {
        webAppReady = true
        deliverPending()
    }

    /// Called from the scene's `onOpenURL` for `readymade://share…`.
    func handleOpenURL(_ url: URL) {
        NSLog("[ReadymadeShare] app onOpenURL: %@", url.absoluteString)
        guard url.scheme?.lowercased() == "readymade", url.host == "share" else {
            return
        }
        deliverPending()
    }

    /// Called whenever the app becomes active. This is the reliable pickup path:
    /// a share extension cannot dependably launch its host app on modern iOS
    /// (`extensionContext.open` returns false; the legacy `openURL:` selector is
    /// a sandboxed no-op), so instead of relying on the deep link we drain the
    /// shared inbox every time the user lands in the app — whether it
    /// auto-switched or they opened it themselves.
    func appDidBecomeActive() {
        NSLog("[ReadymadeShare] app became active")
        // The "Open in Readymade" notifications the share extension posted are
        // done with once the app is in front: their shares are drained now.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        deliverPending()
    }

    /// Called from the scene's `onOpenURL` for a file opened in Readymade
    /// ("Open in…" from Files, Mail or another app, for the types declared in
    /// Info.plist). Unlike a share, this launches the app, so no board is chosen
    /// beforehand: the file goes into the inbox untagged, as a share saved with
    /// "Decide later" does, and the in-app picker asks.
    func handleOpenedFile(_ url: URL) {
        NSLog("[ReadymadeShare] opened file: %@", url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.storeOpenedFile(url)
            DispatchQueue.main.async {
                switch outcome {
                case .stored:
                    self.deliverPending(askingForNotifications: false)
                case .tooLarge:
                    Self.presentNotice(
                        title: "File too large",
                        message: "Readymade accepts files up to \(ByteCountFormatter.string(fromByteCount: Int64(ShareInbox.maxFilePayloadBytes), countStyle: .file))."
                    )
                case .failed:
                    Self.presentNotice(title: "Could not open the file", message: "Readymade could not read it.")
                }
            }
        }
    }

    private enum OpenedFileOutcome { case stored, tooLarge, failed }

    /// Copies an opened file into the inbox as the payload of a new item. The
    /// file may be the original (opened in place, security-scoped, possibly in
    /// iCloud and not yet downloaded — hence the coordinated read) or a copy
    /// iOS put in Documents/Inbox, which is removed once it is in.
    private static func storeOpenedFile(_ url: URL) -> OpenedFileOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            removeInboxCopy(url)
        }
        var outcome = OpenedFileOutcome.failed
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            let size = (try? readURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= ShareInbox.maxFilePayloadBytes else {
                outcome = .tooLarge
                return
            }
            let mimeType = UTType(filenameExtension: readURL.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            let item = SharedItem(
                url: nil,
                title: nil,
                text: nil,
                file: SharedFile(name: readURL.lastPathComponent, mimeType: mimeType, size: size)
            )
            do {
                try ShareInbox.storeFilePayload(from: readURL, id: item.id)
                try ShareInbox.write(item)
                outcome = .stored
            } catch {
                NSLog("[ReadymadeShare] storing opened file FAILED: %@", error.localizedDescription)
                ShareInbox.removeFilePayload(id: item.id)
            }
        }
        if let coordinationError {
            NSLog("[ReadymadeShare] reading opened file FAILED: %@", coordinationError.localizedDescription)
        }
        return outcome
    }

    /// A file "copied to" Readymade lands in Documents/Inbox, which the Files
    /// app shows under On My iPhone. Once it is in the share inbox it is not
    /// needed there.
    private static func removeInboxCopy(_ url: URL) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(inbox + "/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A one-button alert over whatever is showing; the page is not involved,
    /// since nothing reached it.
    private static func presentNotice(title: String, message: String) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    /// Drains the App Group inbox into the page. Each envelope is removed only
    /// after the JS call succeeds, so an item is consumed exactly once even if
    /// both the open-URL and the load-finished paths fire.
    ///
    /// The first time a share made in the extension reaches the app, the app
    /// asks to post notifications: from then on the extension tells the person,
    /// once a share is saved, that one tap opens Readymade with it waiting.
    /// iOS asks only once; later calls return what was answered.
    private func deliverPending(askingForNotifications: Bool = true) {
        // Payloads whose share was abandoned (picker cancelled, board deleted)
        // are never fetched+released by the web app; drop old ones here.
        ShareInbox.sweepStalePayloads()

        let items = ShareInbox.pending()
        NSLog("[ReadymadeShare] deliverPending: ready=%@ webView=%@ items=%d",
              webAppReady ? "YES" : "NO", webView == nil ? "nil" : "set", items.count)
        guard webAppReady, let webView else { return }
        if askingForNotifications && !items.isEmpty {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }

        for item in items {
            guard let data = try? JSONEncoder().encode(item),
                  let json = String(data: data, encoding: .utf8) else {
                continue
            }
            let js = "window.__readymadeDeliverShare && window.__readymadeDeliverShare(\(json));"
            webView.evaluateJavaScript(js) { _, error in
                if error == nil {
                    ShareInbox.remove(id: item.id)
                } else {
                    NSLog("Readymade share delivery failed: %@", error!.localizedDescription)
                }
            }
        }
    }
}
