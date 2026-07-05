import AuthenticationServices
import CryptoKit
import Foundation
import UIKit
import WebKit

/// Native Auth0 login for the web app: the WKWebView cannot run Auth0's web
/// redirect (custom-scheme origin, no popup support), so the JS side posts
/// `{ domain, clientId, scheme }` to the `hkpAuth` message handler and this
/// bridge drives the RFC 8252 native flow — Authorization Code + PKCE in an
/// ASWebAuthenticationSession, then a token exchange over URLSession — and
/// replies with `{ idToken }` (or `{ cancelled: true }` when the user closes
/// the sheet).
///
/// Prerequisite: `<scheme>://auth/callback` must be listed in the Auth0
/// application's Allowed Callback URLs (the app is a Native client, PKCE,
/// no secret).
final class AuthSessionBridge: NSObject, WKScriptMessageHandlerWithReply {
    private var session: ASWebAuthenticationSession?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == "hkpAuth",
              let body = message.body as? [String: Any],
              let domain = body["domain"] as? String,
              let clientId = body["clientId"] as? String,
              let scheme = body["scheme"] as? String
        else {
            replyHandler(nil, "Invalid login request")
            return
        }

        guard self.session == nil else {
            replyHandler(nil, "A login is already in progress")
            return
        }

        let verifier = Self.randomURLSafe(byteCount: 32)
        let challenge = Self.s256Challenge(of: verifier)
        let state = Self.randomURLSafe(byteCount: 16)
        let redirectUri = "\(scheme)://auth/callback"

        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else {
            replyHandler(nil, "Could not build the authorize URL")
            return
        }

        NSLog("Meander iOS login: redirect_uri %@ — must be an Allowed Callback URL in Auth0.", redirectUri)

        let reply: (Any?, String?) -> Void = { value, error in
            DispatchQueue.main.async { replyHandler(value, error) }
        }

        let session = ASWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: scheme
        ) { [weak self] callbackURL, error in
            self?.session = nil

            if let error {
                let isCancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                if isCancelled {
                    reply(["cancelled": true], nil)
                } else {
                    reply(nil, error.localizedDescription)
                }
                return
            }

            guard let callbackURL,
                  let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
            else {
                reply(nil, "Login redirect could not be parsed")
                return
            }

            if let oauthError = items.first(where: { $0.name == "error" })?.value {
                let description = items.first(where: { $0.name == "error_description" })?.value
                reply(nil, description ?? oauthError)
                return
            }

            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value
            else {
                reply(nil, "Login redirect did not include a valid code")
                return
            }

            Self.exchangeCode(
                domain: domain,
                clientId: clientId,
                code: code,
                verifier: verifier,
                redirectUri: redirectUri,
                reply: reply
            )
        }

        session.presentationContextProvider = PresentationAnchorProvider.shared
        self.session = session

        DispatchQueue.main.async {
            if !session.start() {
                self.session = nil
                reply(nil, "Could not present the login window")
            }
        }
    }

    // MARK: - Token exchange

    private static func exchangeCode(
        domain: String,
        clientId: String,
        code: String,
        verifier: String,
        redirectUri: String,
        reply: @escaping (Any?, String?) -> Void
    ) {
        guard let tokenURL = URL(string: "https://\(domain)/oauth/token") else {
            reply(nil, "Could not build the token URL")
            return
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                reply(nil, "Token exchange failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idToken = json["id_token"] as? String
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                reply(nil, "Token exchange failed (\(status))")
                return
            }
            reply(["idToken": idToken], nil)
        }.resume()
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func s256Challenge(of verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Anchors the ASWebAuthenticationSession sheet on the app's key window.
private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchorProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return keyWindow ?? ASPresentationAnchor()
    }
}
