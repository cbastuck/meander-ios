import Foundation
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
        deliverPending()
    }

    /// Drains the App Group inbox into the page. Each envelope is removed only
    /// after the JS call succeeds, so an item is consumed exactly once even if
    /// both the open-URL and the load-finished paths fire.
    private func deliverPending() {
        // Payloads whose share was abandoned (picker cancelled, board deleted)
        // are never fetched+released by the web app; drop old ones here.
        ShareInbox.sweepStalePayloads()

        let items = ShareInbox.pending()
        NSLog("[ReadymadeShare] deliverPending: ready=%@ webView=%@ items=%d",
              webAppReady ? "YES" : "NO", webView == nil ? "nil" : "set", items.count)
        guard webAppReady, let webView else { return }

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
