import SwiftUI
import UIKit

private final class MeanderIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let autoStart = (Bundle.main.object(forInfoDictionaryKey: "HKPRuntimeAutoStart") as? Bool) ?? false
        guard autoStart else {
            return true
        }

        let port = (Bundle.main.object(forInfoDictionaryKey: "HKPRuntimePort") as? NSNumber)?.uintValue ?? 5556
        let allowedOrigins = (Bundle.main.object(forInfoDictionaryKey: "HKPRuntimeAllowedOrigins") as? String) ?? "*"

        do {
            try HKPRuntimeHost.shared().start(withPort: UInt(port), allowedOrigins: allowedOrigins)
            if let runtimeURL = HKPRuntimeHost.shared().runtimeBaseURL {
                NSLog("Embedded hkp-rt started at %@", runtimeURL)
            }
        } catch {
            NSLog("Embedded hkp-rt failed to start: %@", error.localizedDescription)
        }

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        HKPRuntimeHost.shared().stop()
    }
}

@main
struct MeanderIOSApp: App {
    @UIApplicationDelegateAdaptor(MeanderIOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            BoardListView()
        }
    }
}
