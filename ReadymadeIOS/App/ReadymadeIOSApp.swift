import SwiftUI
import UIKit

private final class ReadymadeIOSAppDelegate: NSObject, UIApplicationDelegate {
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
            try HKPRuntimeHost.shared().start(
                withPort: UInt(port),
                allowedOrigins: allowedOrigins,
                deviceName: UIDevice.current.name
            )
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
struct ReadymadeIOSApp: App {
    @UIApplicationDelegateAdaptor(ReadymadeIOSAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BoardListView()
                // Share extension handoff: readymade://share?id=… — the router
                // drains the App Group inbox into the running web app. Kept as a
                // best-effort fast path; the reliable pickup is scenePhase below.
                .onOpenURL { url in
                    ShareRouter.shared.handleOpenURL(url)
                }
        }
        // A share extension can't reliably foreground its host app, so drain the
        // shared inbox whenever the app becomes active — this is what actually
        // surfaces a shared item, whether the app auto-switched or the user
        // opened it manually after sharing.
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                ShareRouter.shared.appDidBecomeActive()
            }
        }
    }
}
