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
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

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

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        aidokuLegacyMarkMemoryPressure()
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyMemoryTrimRequested"), object: nil)
        aidokuLegacyTrimVolatileCaches()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        beginShortBackgroundTask(application)
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyAppDidEnterBackground"), object: nil)
        aidokuLegacyTrimVolatileCaches()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyAppWillEnterForeground"), object: nil)
        endShortBackgroundTask(application)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyAppDidEnterBackground"), object: nil)
        aidokuLegacyTrimVolatileCaches()
        endShortBackgroundTask(application)
    }

    private func registerDefaults() {
        let isLegacyIPadAir = UIDevice.current.isFirstGenerationIPadAir
        UserDefaults.standard.register(
            defaults: [
                "AidokuLegacy.reader.downsampleImages": isLegacyIPadAir,
                "AidokuLegacy.reader.fitToScreen": true,
                "AidokuLegacy.reader.mode": "verticalFit",
                "AidokuLegacy.reader.maxImageHeight": isLegacyIPadAir ? 768 : 2200,
                "AidokuLegacy.reader.upscaleImages": false,
                "AidokuLegacy.reader.prefetchPages": 2,
                "AidokuLegacy.reader.backgroundColor": "black",
                "AidokuLegacy.reader.showPageNumber": true,
                "AidokuLegacy.reader.showTapZones": true,
                "AidokuLegacy.reader.restoreLastSession": true,
                "AidokuLegacy.appearance.darkTheme": false,
                "AidokuLegacy.library.automaticUpdates": false,
                "AidokuLegacy.sources.automaticUpdates": true
            ]
        )
    }

    private func registerImageCoders() {
        if UIDevice.current.isFirstGenerationIPadAir || ProcessInfo.processInfo.physicalMemory <= 1_350_000_000 {
            SDImageCache.shared.config.shouldCacheImagesInMemory = false
            SDImageCache.shared.config.maxMemoryCost = 1024 * 1024
            SDImageCache.shared.config.maxMemoryCount = 4
        }
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    }

    private func beginShortBackgroundTask(_ application: UIApplication) {
        guard backgroundTaskIdentifier == .invalid else { return }
        backgroundTaskIdentifier = application.beginBackgroundTask(withName: "AidokuLegacyBackgroundTrim") { [weak self] in
            self?.endShortBackgroundTask(application)
        }
    }

    private func endShortBackgroundTask(_ application: UIApplication) {
        guard backgroundTaskIdentifier != .invalid else { return }
        application.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
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
