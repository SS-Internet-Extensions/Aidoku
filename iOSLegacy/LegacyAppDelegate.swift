//
//  LegacyAppDelegate.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit

@UIApplicationMain
final class LegacyAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.tintColor = LegacyPalette.accent
        window.rootViewController = UINavigationController(rootViewController: LegacyRootViewController())
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}
