//
//  LegacyAppDelegate.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit
import Darwin
import SDWebImage
import SDWebImageWebPCoder

@UIApplicationMain
final class LegacyAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.tintColor = LegacyPalette.accent
        registerDefaults()
        registerImageCoders()
        window.rootViewController = LegacyTabBarController()
        self.window = window
        window.makeKeyAndVisible()
        return true
    }

    private func registerDefaults() {
        let isLegacyIPadAir = UIDevice.current.isFirstGenerationIPadAir
        UserDefaults.standard.register(
            defaults: [
                "AidokuLegacy.reader.downsampleImages": isLegacyIPadAir,
                "AidokuLegacy.reader.fitToScreen": true,
                "AidokuLegacy.reader.mode": "pagedLTR",
                "AidokuLegacy.reader.maxImageHeight": isLegacyIPadAir ? 1400 : 2200,
                "AidokuLegacy.reader.prefetchPages": isLegacyIPadAir ? 1 : 2,
                "AidokuLegacy.reader.backgroundColor": "black",
                "AidokuLegacy.appearance.darkTheme": false
            ]
        )
    }

    private func registerImageCoders() {
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    }
}

private extension UIDevice {
    var isFirstGenerationIPadAir: Bool {
        return ["iPad4,1", "iPad4,2", "iPad4,3"].contains(modelIdentifier)
    }

    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
