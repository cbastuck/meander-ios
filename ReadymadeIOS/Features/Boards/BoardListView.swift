import Foundation
import SwiftUI
import WebKit

struct BoardListView: View {
    var body: some View {
        MeanderWebView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}

private struct MeanderWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "hkp")

        // Honour `playsinline`: without this an iPhone WKWebView plays every
        // video in the fullscreen player. Muted video (the start page's news
        // teasers) may start on its own; anything with sound still waits for
        // a tap. Under the default (.all) a teaser's play() was refused on
        // load but allowed right after any tap — e.g. the back link — and so
        // jumped fullscreen.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio

        // Inject an unambiguous platform marker before any page JS runs.
        // The web app reads window.__MEANDER_IOS__ instead of sniffing the UA.
        let platformScript = WKUserScript(
            source: "window.__MEANDER_IOS__ = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(platformScript)

        // Expose the local runtime to the web app's DiscoveryApi. It is reached
        // through the existing hkp://remotes/<name> proxy (no cross-origin http
        // fetch), so `${runtimeBaseURL}/discover` resolves to the embedded
        // runtime's /discover endpoint.
        let runtimeRemoteName = AppBridgeConfig.runtimeRemoteName
        let runtimeConfigScript = WKUserScript(
            source: """
            window.__MEANDER_CONFIG__ = Object.assign(window.__MEANDER_CONFIG__ || {}, \
            { runtimeBaseURL: "hkp://remotes/\(runtimeRemoteName)" });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(runtimeConfigScript)

        // Share bridge: defines the sink the native side calls when a share is
        // delivered (see ShareRouter). Injected at document start so it exists
        // before React mounts — envelopes that arrive early queue on
        // window.__READYMADE_SHARES__ and the web app drains them on mount;
        // later ones invoke window.__readymadeOnShare directly.
        let shareBridgeScript = WKUserScript(
            source: """
            window.__READYMADE_SHARES__ = window.__READYMADE_SHARES__ || [];
            window.__readymadeDeliverShare = function (env) {
              try {
                window.__READYMADE_SHARES__.push(env);
                if (window.__readymadeOnShare) { window.__readymadeOnShare(env); }
              } catch (e) {}
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(shareBridgeScript)

        // Forward JS console output and uncaught errors to the native (Xcode) console.
        // Comment out this line to disable the bridge; see JSConsoleBridge.swift.
        JSConsoleBridge.install(into: configuration)

        // The vault and the grants, for the app's own page only (SecretsPage).
        // A dev server is one of the app's pages while it is serving the app.
        #if DEBUG
        if let devURL = Bundle.main.object(forInfoDictionaryKey: "DEV_WEBAPP_URL") as? String,
           let url = URL(string: devURL), let scheme = url.scheme, let host = url.host {
            SecretsPage.ownPages.append("\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")")
        }
        #endif
        SecretsPage.install(into: configuration.userContentController)

        // Bridge for the web app to push the signed-in user's email to the
        // embedded runtime's auth allow-list (RuntimeUserSync → setRuntimeAllowedUser).
        configuration.userContentController.add(
            context.coordinator, name: "hkpRuntimeAuth")

        // Native Auth0 login (ASWebAuthenticationSession + PKCE); the web app
        // awaits the reply of hkpAuth.postMessage({domain, clientId, scheme}).
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator.authBridge, contentWorld: .page, name: "hkpAuth")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Let the share router push captured shares into this page, and the
        // launch router tell it a board was launched from outside the app.
        ShareRouter.shared.register(webView: webView)
        LaunchRouter.shared.register(webView: webView)

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        #if DEBUG
        // In debug builds only, DEV_WEBAPP_URL in Info.plist redirects to a local dev server.
        let devURL = Bundle.main.object(forInfoDictionaryKey: "DEV_WEBAPP_URL") as? String
        if let devURL = devURL, let url = URL(string: devURL) {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: URL(string: "hkp://app/index.html")!))
        }
        #else
        webView.load(URLRequest(url: URL(string: "hkp://app/index.html")!))
        #endif
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

private final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let schemeHandler = MeanderSchemeHandler()
    let authBridge = AuthSessionBridge()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        // Receives { email } from the web app and updates the embedded runtime's
        // allow-list so the owner's other devices may drive it (empty = re-locked).
        case "hkpRuntimeAuth":
            var emails: [String] = []
            if let body = message.body as? [String: Any],
               let email = body["email"] as? String,
               !email.isEmpty {
                emails = [email]
            }
            HKPRuntimeHost.shared().setLoginUsers(emails)

        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NSLog("Meander iOS nav start: %@", webView.url?.absoluteString ?? "?")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        NSLog("Meander iOS nav commit: %@", webView.url?.absoluteString ?? "?")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("Meander iOS nav finish: %@", webView.url?.absoluteString ?? "?")
        // The page (and the injected share bridge) is now live; deliver any
        // shares captured before the web app was ready (e.g. cold launch from
        // the share sheet).
        ShareRouter.shared.webAppDidFinishLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Meander iOS navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Meander iOS provisional navigation failed: %@", error.localizedDescription)
    }
}

private final class MeanderSchemeHandler: NSObject, WKURLSchemeHandler {
    private let boards = BoardLibrary.shared
    private let history = BoardHistoryStore()
    private let startPageTree = StartPageTreeStore()
    private let presetStore = PresetStore()
    private let remoteStore = RemoteStore()
    private let remoteRuntime = RemoteRuntimeBridge(
        remoteName: AppBridgeConfig.runtimeRemoteName,
        runtimeBaseURL: AppBridgeConfig.runtimeBaseURL
    )
    private let apiHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, \(SecretsPage.tokenHeader)",
    ]

    /// Tasks WebKit has started and not stopped. A task answered later, off the
    /// main thread, is answered only if it is still here: answering a stopped
    /// task raises an exception.
    private var liveTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        liveTasks.insert(ObjectIdentifier(urlSchemeTask))
        do {
            try handle(urlSchemeTask, webView: webView)
        } catch {
            respond(
                to: urlSchemeTask,
                statusCode: 500,
                data: jsonData(["error": error.localizedDescription]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func handle(_ task: WKURLSchemeTask, webView: WKWebView) throws {
        guard let url = task.request.url else {
            respond(to: task, statusCode: 400, data: Data(), mimeType: nil, headers: apiHeaders)
            return
        }

        let method = (task.request.httpMethod ?? "GET").uppercased()

        if method == "OPTIONS" {
            respond(to: task, statusCode: 204, data: Data(), mimeType: nil, headers: apiHeaders)
            return
        }

        switch url.host {
        case "app":
            try serveAppResource(for: url, task: task)
        case "boards":
            serveBoards(for: task, url: url, method: method)
        case "history":
            try serveHistory(for: task, url: url, method: method)
        case "startpage":
            try serveStartPage(for: task, method: method)
        case "presets":
            try servePresets(for: task, url: url, method: method)
        case "remotes":
            try serveRemotes(for: task, url: url, method: method)
        case "settings":
            serveSettings(for: task, method: method)
        case "share-files":
            serveShareFiles(for: task, url: url, method: method)
        case "mint-token":
            serveMintToken(for: task, url: url, method: method)
        case "home-screen":
            serveHomeScreen(for: task, url: url, method: method)
        case "secrets":
            serveSecrets(for: task, url: url, method: method, webView: webView)
        default:
            respond(
                to: task,
                statusCode: 404,
                data: jsonData(["error": "Unknown route: \(url.absoluteString)"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    private func serveSettings(for task: WKURLSchemeTask, method: String) {
        let host = HKPRuntimeHost.shared()

        func current() -> [String: Any] {
            return [
                "allowExternalRuntimeAccess": host.externalAccessEnabled,
                "allowedUsers": host.manualAllowedUsers,
            ]
        }

        switch method {
        case "GET":
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(current()),
                mimeType: "application/json",
                headers: apiHeaders
            )
        case "POST":
            if let body = requestBody(from: task.request),
               let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                if let expose = payload["allowExternalRuntimeAccess"] as? Bool {
                    host.externalAccessEnabled = expose
                }
                if let users = payload["allowedUsers"] as? [String] {
                    host.manualAllowedUsers = users
                }
            }
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(current()),
                mimeType: "application/json",
                headers: apiHeaders
            )
        default:
            respond(
                to: task,
                statusCode: 405,
                data: jsonData(["error": "Unsupported settings request"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    // Binary payloads of shared items (hkp://share-files/<id>). The share
    // extension stores the bytes in the App Group next to the JSON envelope;
    // the web app fetches them on demand when it injects the share into a
    // board (GET) and releases them once consumed (DELETE). Keeping the bytes
    // out of the envelope avoids pushing megabytes through evaluateJavaScript.
    private func serveShareFiles(for task: WKURLSchemeTask, url: URL, method: String) {
        let id = normalizedPath(url.path)
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else {
            respond(
                to: task,
                statusCode: 400,
                data: jsonData(["error": "Missing share file id"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
            return
        }

        switch method {
        case "GET":
            guard let data = ShareInbox.readFilePayload(id: id) else {
                respond(
                    to: task,
                    statusCode: 404,
                    data: jsonData(["error": "Unknown share file: \(id)"]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
                return
            }
            respond(
                to: task,
                statusCode: 200,
                data: data,
                mimeType: "application/octet-stream",
                headers: apiHeaders
            )
        case "DELETE":
            ShareInbox.removeFilePayload(id: id)
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(["deleted": id]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        default:
            respond(
                to: task,
                statusCode: 405,
                data: jsonData(["error": "Unsupported share-files request"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    // Boards pinned to the Home Screen (hkp://home-screen/…):
    //   GET    pins               the pinned list, newest first
    //   POST   pins               pin { kind, id, title }; iOS cannot place an
    //                             icon itself, so the answer says "manual"
    //   DELETE pins/<kind>/<id>   unpin
    //   POST   launch             take the board a widget, quick action or
    //                             intent asked to open, once (see LaunchRouter)
    //   POST   shortcuts          open the Shortcuts app, where a pinned board
    //                             becomes a Home Screen icon
    private func serveHomeScreen(for task: WKURLSchemeTask, url: URL, method: String) {
        let segments = normalizedPath(url.path).split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }

        func reply(_ statusCode: Int, _ body: Any) {
            respond(
                to: task,
                statusCode: statusCode,
                data: jsonData(body),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }

        func encoded(_ pins: [HomeScreenPin]) -> [[String: String]] {
            pins.map { ["kind": $0.kind, "id": $0.id, "title": $0.title] }
        }

        switch (method, segments.first ?? "", segments.count) {
        case ("GET", "pins", 1):
            reply(200, ["pins": encoded(HomeScreenPins.list())])

        case ("POST", "pins", 1):
            guard let body = requestBody(from: task.request),
                  let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let kind = payload["kind"] as? String,
                  let id = payload["id"] as? String else {
                reply(400, ["error": "A pin needs a kind and an id"])
                return
            }
            let title = (payload["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            do {
                let pins = try HomeScreenPins.add(HomeScreenPin(kind: kind, id: id, title: title))
                LaunchRouter.pinsDidChange(pins)
                reply(200, ["pins": encoded(pins), "homeScreen": "manual"])
            } catch {
                reply(400, ["error": error.localizedDescription])
            }

        case ("DELETE", "pins", 3):
            do {
                let pins = try HomeScreenPins.remove(kind: segments[1], id: segments[2])
                LaunchRouter.pinsDidChange(pins)
                reply(200, ["pins": encoded(pins)])
            } catch {
                reply(500, ["error": error.localizedDescription])
            }

        case ("POST", "launch", 1):
            if let target = LaunchRouter.shared.take() {
                reply(200, ["target": ["kind": target.kind, "id": target.id]])
            } else {
                reply(200, ["target": NSNull()])
            }

        case ("POST", "shortcuts", 1):
            DispatchQueue.main.async {
                UIApplication.shared.open(URL(string: "shortcuts://")!)
            }
            reply(200, [String: String]())

        default:
            reply(404, ["error": "Unknown home-screen request: \(method) \(url.absoluteString)"])
        }
    }

    // Secrets (hkp://secrets/…), in the Keychain, for the app's own page only
    // (see SecretsPage). Names and audiences come back; a value never does —
    // the page already has every value, from the injection, and a settings
    // view has no reason to show one.
    //   GET    values            alias -> hosts it may be sent to
    //   POST   values/<alias>    { value?, audience? }: whichever is given is
    //                            set, the other is left as it was
    //   DELETE values/<alias>
    //   POST   grants            { key, aliases }: merged into what was granted
    //   DELETE grants            { key }
    private func serveSecrets(for task: WKURLSchemeTask, url: URL, method: String, webView: WKWebView) {
        func reply(_ statusCode: Int, _ body: Any) {
            respond(
                to: task,
                statusCode: statusCode,
                data: jsonData(body),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }

        guard task.request.value(forHTTPHeaderField: SecretsPage.tokenHeader) == SecretsPage.token else {
            reply(403, ["error": "Secrets are kept for the app's own page"])
            return
        }

        let vault = DeviceVault.shared
        let grants = SecretGrants.shared
        // url.path is already decoded. An alias is limited to what a reference
        // can express, so there is nothing in one to decode again.
        let segments = normalizedPath(url.path).split(separator: "/").map(String.init)
        let payload = requestBody(from: task.request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]

        do {
            switch (method, segments.first ?? "", segments.count) {
            case ("GET", "values", 1):
                var audiences: [String: [String]] = [:]
                for (alias, entry) in vault.all() {
                    audiences[alias] = entry.audience
                }
                reply(200, audiences)

            case ("POST", "values", 2):
                let alias = segments[1]
                guard alias.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
                    reply(400, ["error": "Use letters, digits, dots, hyphens and underscores only"])
                    return
                }
                let value = payload["value"] as? String
                let audience = payload["audience"] as? [String]
                guard value != nil || audience != nil else {
                    reply(400, ["error": "Nothing to set: give a value, an audience or both"])
                    return
                }
                if let value {
                    guard !value.isEmpty else {
                        reply(400, ["error": "A secret with no value is the same as not having one"])
                        return
                    }
                    try vault.setValue(value, for: alias)
                }
                if let audience {
                    let constrained = try vault.setAudience(audience, for: alias)
                    guard constrained else {
                        reply(404, ["error": "No secret called \(alias)"])
                        return
                    }
                }
                SecretsPage.install(into: webView.configuration.userContentController)
                reply(200, ["saved": alias])

            case ("DELETE", "values", 2):
                // Gone either way, which is what was asked for.
                _ = vault.delete(segments[1])
                SecretsPage.install(into: webView.configuration.userContentController)
                reply(200, ["deleted": segments[1]])

            case ("POST", "grants", 1):
                guard let key = payload["key"] as? String, !key.isEmpty,
                      let aliases = payload["aliases"] as? [String] else {
                    reply(400, ["error": "A grant needs a key and aliases"])
                    return
                }
                try grants.grant(aliases, under: key)
                SecretsPage.install(into: webView.configuration.userContentController)
                reply(200, ["granted": key])

            case ("DELETE", "grants", 1):
                guard let key = payload["key"] as? String, !key.isEmpty else {
                    reply(400, ["error": "Which grant? Give its key"])
                    return
                }
                try grants.revoke(key)
                SecretsPage.install(into: webView.configuration.userContentController)
                reply(200, ["revoked": key])

            default:
                reply(404, ["error": "Unknown secrets request: \(method) \(url.absoluteString)"])
            }
        } catch {
            reply(500, ["error": error.localizedDescription])
        }
    }

    // Hierarchical mint-token namespace (hkp://mint-token/<action>). The action
    // names the semantic capability; one is wired today. Add a case as more
    // mint-token actions are introduced.
    // NOTE: needs Xcode build verification (not compiled in this environment).
    private func serveMintToken(for task: WKURLSchemeTask, url: URL, method: String) {
        switch url.path {
        case "/process-runtime":
            serveMintProcessRuntimeToken(for: task, method: method)
        default:
            respond(
                to: task,
                statusCode: 404,
                data: jsonData(["error": "Unknown mint-token action: \(url.absoluteString)"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    // Mints a scoped capability token for the embedded runtime. Reachable only
    // through the hkp:// scheme — i.e. from this app's own webview — so being
    // able to call it is itself the authorization. The token authorizes POST
    // /runtimes/<runtimeId> and nothing else; it is handed to an out-of-band
    // device (a phone) via a QR code.
    private func serveMintProcessRuntimeToken(for task: WKURLSchemeTask, method: String) {
        guard method == "POST" else {
            respond(
                to: task,
                statusCode: 405,
                data: jsonData(["error": "Unsupported mint-token/process-runtime request"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
            return
        }

        guard let body = requestBody(from: task.request),
              let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let runtimeId = payload["runtimeId"] as? String,
              !runtimeId.isEmpty else {
            respond(
                to: task,
                statusCode: 400,
                data: jsonData(["error": "Missing runtimeId"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
            return
        }

        guard let token = HKPRuntimeHost.shared().mintProcessRuntimeGrant(forRuntime: runtimeId) else {
            respond(
                to: task,
                statusCode: 404,
                data: jsonData(["error": "Unknown runtime or unavailable"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
            return
        }

        respond(
            to: task,
            statusCode: 200,
            data: jsonData(["token": token]),
            mimeType: "application/json",
            headers: apiHeaders
        )
    }

    private func serveAppResource(for url: URL, task: WKURLSchemeTask) throws {
        let path = normalizedPath(url.path)
        let relativePath: String

        if path.isEmpty || path == "index.html" {
            relativePath = "index.html"
        } else if path.hasPrefix("assets/") {
            relativePath = path
        } else {
            relativePath = "index.html"
        }

        let fileURL = try bundledWebAppURL(for: relativePath)
        let data = try Data(contentsOf: fileURL)
        respond(to: task, statusCode: 200, data: data, mimeType: mimeType(for: fileURL), headers: [:])
    }

    // The saved boards (hkp://boards/…), in the board library: iCloud Drive
    // when it is on, the app's Documents otherwise. Answered from the
    // library's queue, because a board iCloud has not downloaded yet is
    // downloaded as it is read.
    private func serveBoards(for task: WKURLSchemeTask, url: URL, method: String) {
        let boardName = normalizedPath(url.path).removingPercentEncoding ?? normalizedPath(url.path)
        // "?meta=1" asks for the listing as objects carrying each board's
        // last-write time instead of bare names.
        let wantsMetadata = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "meta" }
            .map { $0.value != "0" } ?? false
        let payload = method == "POST" ? requestBody(from: task.request) : nil
        let library = boards

        respondLater(to: task) { [jsonData] in
            switch (method, boardName.isEmpty) {
            case ("GET", true):
                let entries = library.list()
                return (200, wantsMetadata
                    ? jsonData(entries.map { ["name": $0.name, "modified": $0.modified] })
                    : jsonData(entries.map(\.name)))
            case ("GET", false):
                return (200, try library.load(boardName))
            case ("POST", false):
                guard let payload, !payload.isEmpty else {
                    return (400, jsonData(["error": "Missing board payload"]))
                }
                try library.save(payload, as: boardName)
                return (200, jsonData(["saved": boardName]))
            case ("DELETE", false):
                try library.delete(boardName)
                return (200, jsonData(["deleted": boardName]))
            default:
                return (405, jsonData(["error": "Unsupported boards request"]))
            }
        }
    }

    /// Runs `work` on the board library's queue and answers `task` with what it
    /// returns, as JSON, on the main thread — unless WebKit stopped the task in
    /// the meantime. A board that is not there is a 404, any other failure a 500.
    private func respondLater(
        to task: WKURLSchemeTask,
        _ work: @escaping () throws -> (Int, Data)
    ) {
        let id = ObjectIdentifier(task)
        boards.queue.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard self.liveTasks.contains(id) else {
                    return
                }
                let (status, data): (Int, Data)
                switch result {
                case .success(let answer):
                    (status, data) = answer
                case .failure(BoardLibraryError.notFound(let name)):
                    (status, data) = (404, self.jsonData(["error": "No board called \(name)"]))
                case .failure(BoardLibraryError.invalidBoardName):
                    (status, data) = (400, self.jsonData(["error": "Invalid board name"]))
                case .failure(let error):
                    (status, data) = (500, self.jsonData(["error": error.localizedDescription]))
                }
                self.respond(
                    to: task,
                    statusCode: status,
                    data: data,
                    mimeType: "application/json",
                    headers: self.apiHeaders
                )
            }
        }
    }

    // A board's history (hkp://history/…), kept on this device:
    //   GET    history/           every board with one, and its latest time
    //   GET    history/<board>    the entries, newest first
    //   POST   history/<board>    push an entry (see BoardHistoryStore)
    //   DELETE history/<board>    forget it
    private func serveHistory(for task: WKURLSchemeTask, url: URL, method: String) throws {
        let boardName = normalizedPath(url.path).removingPercentEncoding ?? normalizedPath(url.path)

        func reply(_ statusCode: Int, _ data: Data) {
            respond(to: task, statusCode: statusCode, data: data, mimeType: "application/json", headers: apiHeaders)
        }

        switch (method, boardName.isEmpty) {
        case ("GET", true):
            reply(200, jsonData(history.summaries()))
        case ("GET", false):
            reply(200, history.load(boardName))
        case ("POST", false):
            guard BoardFileName.isValid(boardName), let body = requestBody(from: task.request), !body.isEmpty else {
                reply(400, jsonData(["error": "A snapshot needs a board name and an entry"]))
                return
            }
            try history.push(body, for: boardName)
            reply(201, jsonData(["ok": true]))
        case ("DELETE", false):
            history.clear(boardName)
            reply(200, jsonData(["ok": true]))
        default:
            reply(405, jsonData(["error": "Unsupported history request"]))
        }
    }

    // The board finder's folder tree (hkp://startpage), kept on this device.
    private func serveStartPage(for task: WKURLSchemeTask, method: String) throws {
        switch method {
        case "GET":
            if let tree = startPageTree.load() {
                respond(to: task, statusCode: 200, data: tree, mimeType: "application/json", headers: apiHeaders)
            } else {
                respond(
                    to: task,
                    statusCode: 404,
                    data: jsonData(["error": "No folder tree yet"]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
            }
        case "POST":
            guard let body = requestBody(from: task.request), !body.isEmpty else {
                respond(
                    to: task,
                    statusCode: 400,
                    data: jsonData(["error": "Missing folder tree"]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
                return
            }
            try startPageTree.save(body)
            respond(to: task, statusCode: 200, data: jsonData(["ok": true]), mimeType: "application/json", headers: apiHeaders)
        default:
            respond(
                to: task,
                statusCode: 405,
                data: jsonData(["error": "Unsupported startpage request"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    // The preset library: every file listed unparsed (the web app reads them
    // and skips what is not a preset), written and deleted by file name.
    private func servePresets(for task: WKURLSchemeTask, url: URL, method: String) throws {
        let fileName = normalizedPath(url.path).removingPercentEncoding ?? normalizedPath(url.path)

        switch (method, fileName.isEmpty) {
        case ("GET", true):
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(try presetStore.listFiles()),
                mimeType: "application/json",
                headers: apiHeaders
            )
        case ("POST", false):
            guard let payload = requestBody(from: task.request) else {
                respond(
                    to: task,
                    statusCode: 400,
                    data: jsonData(["error": "Missing preset payload"]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
                return
            }
            try presetStore.write(payload, named: fileName)
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(["file": fileName]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        case ("DELETE", false):
            try presetStore.delete(named: fileName)
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(["file": fileName]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        default:
            respond(
                to: task,
                statusCode: 405,
                data: jsonData(["error": "Unsupported presets request"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    // The embedded runtime, always exposed as a remote reachable in-process
    // through the hkp://remotes/<name> proxy. Not persisted — synthesized on
    // every read so it can never be removed or drift from the live runtime.
    private func embeddedRemote() -> [[String: Any]] {
        let defaultPort: Int
        if let configuredPort = remoteRuntime.runtimeBaseURL.port {
            defaultPort = configuredPort
        } else {
            defaultPort = remoteRuntime.runtimeBaseURL.scheme?.lowercased() == "https" ? 443 : 80
        }

        return [[
            "url": "hkp://remotes/\(remoteRuntime.remoteName)",
            "port": defaultPort,
            "name": remoteRuntime.remoteName,
        ]]
    }

    private func serveRemotes(for task: WKURLSchemeTask, url: URL, method: String) throws {
        let path = normalizedPath(url.path)

        // The collection route (hkp://remotes/) is the remotes list itself:
        // the always-present embedded runtime plus any user-added remotes
        // (e.g. peers found through LAN discovery) persisted in RemoteStore.
        if path.isEmpty {
            switch method {
            case "GET":
                respond(
                    to: task,
                    statusCode: 200,
                    data: jsonData(embeddedRemote() + remoteStore.list()),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
            case "POST":
                guard let body = requestBody(from: task.request),
                      let remote = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let name = (remote["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    respond(
                        to: task,
                        statusCode: 400,
                        data: jsonData(["error": "Invalid remote payload"]),
                        mimeType: "application/json",
                        headers: apiHeaders
                    )
                    return
                }
                // The embedded runtime is synthesized, not stored; refuse to
                // shadow it so it can never be duplicated or overwritten.
                guard name != remoteRuntime.remoteName else {
                    respond(
                        to: task,
                        statusCode: 409,
                        data: jsonData(["error": "Reserved remote name"]),
                        mimeType: "application/json",
                        headers: apiHeaders
                    )
                    return
                }
                try remoteStore.save(remote, named: name)
                respond(
                    to: task,
                    statusCode: 200,
                    data: jsonData(["saved": name]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
            case "DELETE":
                guard let body = requestBody(from: task.request),
                      let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let name = payload["name"] as? String else {
                    respond(
                        to: task,
                        statusCode: 400,
                        data: jsonData(["error": "Missing remote name"]),
                        mimeType: "application/json",
                        headers: apiHeaders
                    )
                    return
                }
                try remoteStore.delete(named: name)
                respond(
                    to: task,
                    statusCode: 200,
                    data: jsonData(["deleted": name]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
            default:
                respond(
                    to: task,
                    statusCode: 405,
                    data: jsonData(["error": "Unsupported remotes request"]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
            }
            return
        }

        var segments = path.split(separator: "/").map(String.init)
        guard let remoteName = segments.first, remoteName == remoteRuntime.remoteName else {
            respond(
                to: task,
                statusCode: 404,
                data: jsonData(["error": "Unknown remote"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
            return
        }

        segments.removeFirst()
        let subpath = segments.joined(separator: "/")
        let response = try remoteRuntime.handle(
            method: method,
            path: subpath,
            query: url.query,
            body: requestBody(from: task.request)
        )

        respond(
            to: task,
            statusCode: response.statusCode,
            data: response.data,
            mimeType: response.mimeType,
            headers: apiHeaders
        )
    }

    private func bundledWebAppURL(for relativePath: String) throws -> URL {
        guard !relativePath.contains("..") else {
            throw WebShellError.forbiddenPath
        }

        guard let rootURL = Bundle.main.resourceURL?.appendingPathComponent("WebApp", isDirectory: true) else {
            throw WebShellError.missingBundleResources
        }

        let fileURL = rootURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw WebShellError.missingBundleFile(relativePath)
        }

        return fileURL
    }

    private func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)

            if count < 0 {
                return nil
            }

            if count == 0 {
                break
            }

            data.append(buffer, count: count)
        }

        return data
    }

    private func respond(
        to task: WKURLSchemeTask,
        statusCode: Int,
        data: Data,
        mimeType: String?,
        headers: [String: String]
    ) {
        guard let url = task.request.url else {
            task.didFailWithError(WebShellError.invalidRequest)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(contentHeaders(for: data, mimeType: mimeType)) { current, _ in current }
        )

        guard let response else {
            task.didFailWithError(WebShellError.invalidResponse)
            return
        }

        liveTasks.remove(ObjectIdentifier(task))
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func contentHeaders(for data: Data, mimeType: String?) -> [String: String] {
        var headers = ["Content-Length": String(data.count)]

        if let mimeType {
            headers["Content-Type"] = mimeType
        }

        return headers
    }

    private func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "css":
            return "text/css"
        case "html":
            return "text/html"
        case "js":
            return "application/javascript"
        case "json":
            return "application/json"
        case "svg":
            return "image/svg+xml"
        case "ttf":
            return "font/ttf"
        case "wasm":
            // WebAssembly compiles while it streams in only when served as
            // what it is; otherwise the page falls back to a slower copy.
            return "application/wasm"
        default:
            return "application/octet-stream"
        }
    }

    private func jsonData(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
    }
}

private enum AppBridgeConfig {
    static let runtimeRemoteName = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "HKPRuntimeRemoteName") as? String
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "meander-ios" : trimmed
    }()

    static let runtimeBaseURL = {
        if let embeddedURLString = HKPRuntimeHost.shared().runtimeBaseURL,
           let embeddedURL = URL(string: embeddedURLString),
           let scheme = embeddedURL.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           embeddedURL.host != nil {
            return embeddedURL
        }

        if let configured = Bundle.main.object(forInfoDictionaryKey: "HKPRuntimeBaseURL") as? String,
           let url = URL(string: configured),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host != nil {
            return url
        }

        return URL(string: "http://127.0.0.1:5556")!
    }()
}

/// The preset library: preset files — blocks among them — in Documents/Presets,
/// one per file as the web app names them, or as whoever put them there did.
private final class PresetStore {
    private let fileManager = FileManager.default

    func listFiles() throws -> [[String: String]] {
        try ensureDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let source = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return ["file": url.lastPathComponent, "source": source]
            }
    }

    func write(_ data: Data, named name: String) throws {
        let url = try fileURL(named: name)
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
    }

    func delete(named name: String) throws {
        let url = try fileURL(named: name)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(named name: String) throws -> URL {
        guard name.hasSuffix(".json"), !name.hasPrefix("."),
              !name.contains("/"), !name.contains("..") else {
            throw WebShellError.forbiddenPath
        }
        return directoryURL().appendingPathComponent(name)
    }

    private func directoryURL() -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("Presets", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL(), withIntermediateDirectories: true)
    }
}

/// Persists user-added remotes (e.g. LAN-discovered peers) to a JSON file in
/// Documents, so they survive relaunches. The embedded runtime is not stored
/// here — it is synthesized on read by the scheme handler.
private final class RemoteStore {
    private let fileManager = FileManager.default

    func list() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: remotesFileURL()),
              let remotes = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return remotes
    }

    /// Upsert by name: a repeat add of the same remote replaces the prior entry
    /// rather than duplicating it.
    func save(_ remote: [String: Any], named name: String) throws {
        var remotes = list().filter { ($0["name"] as? String) != name }
        remotes.append(remote)
        try write(remotes)
    }

    func delete(named name: String) throws {
        let remotes = list().filter { ($0["name"] as? String) != name }
        try write(remotes)
    }

    private func write(_ remotes: [[String: Any]]) throws {
        try ensureRemotesDirectory()
        let data = try JSONSerialization.data(withJSONObject: remotes, options: [])
        try data.write(to: remotesFileURL(), options: .atomic)
    }

    private func remotesFileURL() -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("remotes.json")
    }

    private func ensureRemotesDirectory() throws {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    }
}

private enum WebShellError: LocalizedError {
    case forbiddenPath
    case invalidBoardName
    case invalidRequest
    case invalidResponse
    case missingBundleFile(String)
    case missingBundleResources

    var errorDescription: String? {
        switch self {
        case .forbiddenPath:
            return "Forbidden path"
        case .invalidBoardName:
            return "Invalid board name"
        case .invalidRequest:
            return "Invalid request"
        case .invalidResponse:
            return "Invalid response"
        case .missingBundleFile(let path):
            return "Missing bundled web app file: \(path)"
        case .missingBundleResources:
            return "Missing bundled web app resources"
        }
    }
}

private struct RemoteRuntimeResponse {
    let statusCode: Int
    let data: Data
    let mimeType: String
}

private final class RemoteRuntimeBridge {
    let remoteName: String
    let runtimeBaseURL: URL

    init(remoteName: String, runtimeBaseURL: URL) {
        self.remoteName = remoteName
        self.runtimeBaseURL = runtimeBaseURL
    }

    func handle(method: String, path: String, query: String?, body: Data?) throws -> RemoteRuntimeResponse {
        if method == "GET" && path == "health" {
            let health: [String: Any] = [
                "status": "ok",
                "remote": remoteName,
                "runtimeBaseURL": runtimeBaseURL.absoluteString,
            ]
            return jsonResponse(health)
        }

        guard let targetURL = runtimeURL(path: path, query: query) else {
            return errorResponse(statusCode: 500, message: "Failed to build runtime URL")
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var proxiedData = Data()
        var proxiedResponse: HTTPURLResponse?
        var proxiedError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            proxiedData = data ?? Data()
            proxiedResponse = response as? HTTPURLResponse
            proxiedError = error
            semaphore.signal()
        }.resume()

        let waitResult = semaphore.wait(timeout: .now() + 15)
        if waitResult == .timedOut {
            return errorResponse(statusCode: 504, message: "Runtime request timed out")
        }

        if let proxiedError {
            return errorResponse(statusCode: 502, message: "Runtime request failed: \(proxiedError.localizedDescription)")
        }

        guard let proxiedResponse else {
            return errorResponse(statusCode: 502, message: "Runtime did not return an HTTP response")
        }

        let mimeType = proxiedResponse.mimeType ?? "application/json"
        return RemoteRuntimeResponse(statusCode: proxiedResponse.statusCode, data: proxiedData, mimeType: mimeType)
    }

    private func runtimeURL(path: String, query: String?) -> URL? {
        guard var components = URLComponents(url: runtimeBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = components.path == "/" ? "" : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let extraPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var fullPath = ""
        if !basePath.isEmpty {
            fullPath += "/\(basePath)"
        }
        if !extraPath.isEmpty {
            fullPath += "/\(extraPath)"
        }
        components.path = fullPath.isEmpty ? "/" : fullPath
        components.percentEncodedQuery = query

        return components.url
    }

    private func jsonResponse(_ value: Any, statusCode: Int = 200) -> RemoteRuntimeResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
        return RemoteRuntimeResponse(statusCode: statusCode, data: data, mimeType: "application/json")
    }

    private func errorResponse(statusCode: Int, message: String) -> RemoteRuntimeResponse {
        jsonResponse(["error": message], statusCode: statusCode)
    }
}

#Preview {
    BoardListView()
}
