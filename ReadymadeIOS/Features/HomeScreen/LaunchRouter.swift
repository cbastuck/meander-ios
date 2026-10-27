import Foundation
import UIKit
import WebKit
import WidgetKit

/// Where a board launched from outside the app arrives: a widget or a Home
/// Screen shortcut (as a `readymade://board` link), a quick action, the Open
/// Board intent.
///
/// The board is kept until the web app takes it (`hkp://home-screen/launch`),
/// and the page is told one is waiting. Taking rather than delivering is what
/// makes a cold start the same as a warm one: a launch can arrive before the
/// page exists, and the page asks for it as it mounts.
final class LaunchRouter {
    static let shared = LaunchRouter()
    private init() {}

    private weak var webView: WKWebView?
    private var pending: (kind: String, id: String)?

    /// Called by `BoardListView` when the web view is created.
    func register(webView: WKWebView) {
        self.webView = webView
    }

    /// Called from the scene's `onOpenURL`. False for links that are not a
    /// board's, which leaves them to the share router.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        guard let target = HomeScreenPins.target(from: url) else {
            return false
        }
        open(kind: target.kind, id: target.id)
        return true
    }

    @discardableResult
    func handle(shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == Self.quickActionType,
              let link = shortcutItem.userInfo?["url"] as? String,
              let url = URL(string: link) else {
            return false
        }
        return handleOpenURL(url)
    }

    func open(kind: String, id: String) {
        pending = (kind, id)
        webView?.evaluateJavaScript(
            "window.__readymadeOnLaunch && window.__readymadeOnLaunch();",
            completionHandler: nil
        )
    }

    /// The waiting board, once.
    func take() -> (kind: String, id: String)? {
        defer { pending = nil }
        return pending
    }

    // ── Keeping every launch surface in step with the pinned list ────────────

    static let quickActionType = "com.readymadeit.board"

    /// Rebuilds what reads the pinned list from outside the app: the app icon's
    /// quick actions, the widgets, and the intent's parameter suggestions.
    static func pinsDidChange(_ pins: [HomeScreenPin]) {
        DispatchQueue.main.async {
            // iOS shows about four; the newest pins are the ones that matter.
            UIApplication.shared.shortcutItems = pins.prefix(4).map { pin in
                UIApplicationShortcutItem(
                    type: quickActionType,
                    localizedTitle: pin.title,
                    localizedSubtitle: pin.kind == "demo" ? "Demo" : nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "square.grid.2x2"),
                    userInfo: ["url": pin.launchURL.absoluteString as NSString]
                )
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        ReadymadeShortcuts.updateAppShortcutParameters()
    }
}

/// Receives quick actions while the app runs. A SwiftUI app has no scene
/// delegate of its own, so the app delegate names this one for its scene; the
/// cold-start case arrives in the connection options instead (see
/// `ReadymadeIOSAppDelegate`).
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(LaunchRouter.shared.handle(shortcutItem: shortcutItem))
    }
}
