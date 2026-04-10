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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        // Check for DEV_WEBAPP_URL in Info.plist (or use a hardcoded fallback for dev)
        let devURL = Bundle.main.object(forInfoDictionaryKey: "DEV_WEBAPP_URL") as? String
        if let devURL = devURL, let url = URL(string: devURL) {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: URL(string: "hkp://app/index.html")!))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

private final class Coordinator: NSObject, WKNavigationDelegate {
    let schemeHandler = MeanderSchemeHandler()

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Meander iOS navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Meander iOS provisional navigation failed: %@", error.localizedDescription)
    }
}

private final class MeanderSchemeHandler: NSObject, WKURLSchemeHandler {
    private let boardStore = BoardStore()
    private let remoteRuntime = RemoteRuntimeBridge(
        remoteName: AppBridgeConfig.runtimeRemoteName,
        runtimeBaseURL: AppBridgeConfig.runtimeBaseURL
    )
    private let apiHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            try handle(urlSchemeTask)
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func handle(_ task: WKURLSchemeTask) throws {
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
            try serveBoards(for: task, url: url, method: method)
        case "remotes":
            try serveRemotes(for: task, url: url, method: method)
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

    private func serveBoards(for task: WKURLSchemeTask, url: URL, method: String) throws {
        let boardName = normalizedPath(url.path).removingPercentEncoding ?? normalizedPath(url.path)

        switch (method, boardName.isEmpty) {
        case ("GET", true):
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(try boardStore.listBoards()),
                mimeType: "application/json",
                headers: apiHeaders
            )
        case ("GET", false):
            respond(
                to: task,
                statusCode: 200,
                data: try boardStore.loadBoard(named: boardName),
                mimeType: "application/json",
                headers: apiHeaders
            )
        case ("POST", false):
            guard let payload = requestBody(from: task.request) else {
                respond(
                    to: task,
                    statusCode: 400,
                    data: jsonData(["error": "Missing board payload"]),
                    mimeType: "application/json",
                    headers: apiHeaders
                )
                return
            }

            try boardStore.saveBoard(payload, named: boardName)
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(["saved": boardName]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        case ("DELETE", false):
            try boardStore.deleteBoard(named: boardName)
            respond(
                to: task,
                statusCode: 200,
                data: jsonData(["deleted": boardName]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        default:
            respond(
                to: task,
                statusCode: 405,
                data: jsonData(["error": "Unsupported boards request"]),
                mimeType: "application/json",
                headers: apiHeaders
            )
        }
    }

    private func serveRemotes(for task: WKURLSchemeTask, url: URL, method: String) throws {
        let path = normalizedPath(url.path)

        if path.isEmpty {
            let defaultPort: Int
            if let configuredPort = remoteRuntime.runtimeBaseURL.port {
                defaultPort = configuredPort
            } else {
                defaultPort = remoteRuntime.runtimeBaseURL.scheme?.lowercased() == "https" ? 443 : 80
            }

            let remotes: [[String: Any]] = [[
                "url": "hkp://remotes/\(remoteRuntime.remoteName)",
                "port": defaultPort,
                "name": remoteRuntime.remoteName,
            ]]

            respond(
                to: task,
                statusCode: 200,
                data: jsonData(remotes),
                mimeType: "application/json",
                headers: apiHeaders
            )
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

private final class BoardStore {
    private let fileManager = FileManager.default

    func listBoards() throws -> [String] {
        try ensureBoardsDirectory()

        let urls = try fileManager.contentsOfDirectory(
            at: boardsDirectoryURL(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func loadBoard(named name: String) throws -> Data {
        let validatedName = try validate(name)
        return try Data(contentsOf: boardURL(named: validatedName))
    }

    func saveBoard(_ data: Data, named name: String) throws {
        let validatedName = try validate(name)
        try ensureBoardsDirectory()
        try data.write(to: boardURL(named: validatedName), options: .atomic)
    }

    func deleteBoard(named name: String) throws {
        let validatedName = try validate(name)
        let url = boardURL(named: validatedName)

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func boardURL(named name: String) -> URL {
        boardsDirectoryURL().appendingPathComponent("\(name).json")
    }

    private func boardsDirectoryURL() -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("Boards", isDirectory: true)
    }

    private func ensureBoardsDirectory() throws {
        try fileManager.createDirectory(at: boardsDirectoryURL(), withIntermediateDirectories: true)
    }

    private func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw WebShellError.invalidBoardName
        }

        guard !trimmed.contains("/") && !trimmed.contains("..") else {
            throw WebShellError.forbiddenPath
        }

        return trimmed
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
