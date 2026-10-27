import SwiftUI
import UIKit

private final class ReadymadeIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before anything asks for a board: where the library is (iCloud Drive
        // or this device) is resolved off the main thread, and every request
        // for a board queues behind it.
        BoardLibrary.shared.prepare()

        // The quick actions are the pinned list's; rebuild them from it, so a
        // pin made or dropped by another process (the widget's configuration
        // reads the same list) is reflected at the next launch.
        LaunchRouter.pinsDidChange(HomeScreenPins.list())

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

    // A SwiftUI app has no scene delegate unless it names one. This one
    // receives quick actions while the app runs; a quick action that launched
    // the app arrives here instead, in the connection options.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            LaunchRouter.shared.handle(shortcutItem: shortcutItem)
        }
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
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
                // readymade://board?… — a pinned board launched from a widget
                // or a Home Screen shortcut; the launch router keeps it until
                // the web app takes it.
                // Share extension handoff: readymade://share?id=… — the router
                // drains the App Group inbox into the running web app. Kept as a
                // best-effort fast path; the reliable pickup is scenePhase below.
                .onOpenURL { url in
                    if !LaunchRouter.shared.handleOpenURL(url) {
                        ShareRouter.shared.handleOpenURL(url)
                    }
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
