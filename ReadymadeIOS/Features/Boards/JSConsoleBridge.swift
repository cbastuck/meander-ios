import Foundation
import WebKit

/// Forwards JS `console.*` output and uncaught errors from a `WKWebView` into the
/// native (Xcode) console. This keeps diagnostics flowing even when the Web Inspector
/// can't attach or the WebContent main thread is wedged before logs reach the inspector.
///
/// Self-contained on purpose so it's easy to include or exclude: call
/// `JSConsoleBridge.install(into:)` while building the `WKWebViewConfiguration`, or
/// comment out that single line to disable the bridge entirely.
final class JSConsoleBridge: NSObject, WKScriptMessageHandler {
    private static let messageHandlerName = "meanderConsole"

    /// Wires the console bridge into the given configuration. The created handler is
    /// retained by the configuration's user content controller, so the caller doesn't
    /// need to hold on to a reference.
    static func install(into configuration: WKWebViewConfiguration) {
        let bridge = JSConsoleBridge()
        configuration.userContentController.add(bridge, name: messageHandlerName)

        let script = WKUserScript(
            source: bridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName else { return }
        NSLog("[JS] %@", String(describing: message.body))
    }

    // Injected at document start: mirror console.* and uncaught errors to native.
    private static let bridgeSource = """
    (function () {
      function post(level, args) {
        try {
          var parts = Array.prototype.map.call(args, function (a) {
            if (typeof a === 'string') { return a; }
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          });
          window.webkit.messageHandlers.meanderConsole.postMessage(level + ': ' + parts.join(' '));
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level] ? console[level].bind(console) : function () {};
        console[level] = function () { post(level, arguments); original.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) {
        post('uncaught', [e.message + ' @ ' + (e.filename || '?') + ':' + (e.lineno || '?')]);
      });
      window.addEventListener('unhandledrejection', function (e) {
        var r = e && e.reason;
        post('unhandledrejection', [r && r.stack ? r.stack : String(r)]);
      });
      post('bridge', ['console bridge installed @ ' + location.href]);
    })();
    """
}
