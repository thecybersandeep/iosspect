// AppDelegate.swift - UIKit entry that hands the scene over to SwiftUI.
// UIKit because the iOS 13 scene lifecycle is the cleanest way to host
// SwiftUI on jailbroken iOS 15+ without the @main attribute (Theos has
// historic trouble with @main).

import UIKit

@objc(AppDelegate)
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // First-launch bootstrap: generate the browser password and TLS
        // cert if they don't exist yet. ServerControl is idempotent.
        ServerControl.shared.bootstrapIfNeeded()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}
