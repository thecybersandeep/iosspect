// SceneDelegate.swift - hosts the SwiftUI DashboardView inside a
// UIHostingController. iOS 13+ scene lifecycle.

import UIKit
import SwiftUI

@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let win = UIWindow(windowScene: windowScene)
        win.rootViewController = UIHostingController(rootView: DashboardView())
        self.window = win
        win.makeKeyAndVisible()
    }
}
