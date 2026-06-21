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
        presentLaunchCover(over: window)
        LegacyModernAutomaticBackupScheduler.shared.createBackupIfNeeded()
        return true
    }

    // The launch storyboard is system-rendered and can only follow the device's
    // system appearance, so it stays light when the user enables the in-app dark
    // theme. Cover the window with a themed splash matching the in-app theme and
    // fade it out, avoiding a white flash before the themed UI appears.
    private func presentLaunchCover(over window: UIWindow) {
        let cover = UIView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = LegacyPalette.background

        let label = UILabel()
        label.text = "Aidoku"
        label.textColor = LegacyPalette.accent
        label.font = .systemFont(ofSize: 36, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cover.centerYAnchor)
        ])

        window.addSubview(cover)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            UIView.animate(
                withDuration: 0.25,
                animations: { cover.alpha = 0 },
                completion: { _ in cover.removeFromSuperview() }
            )
        }
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        let action = LegacyDeepLinkHandler.action(for: url)
        return LegacyDeepLinkCoordinator.handle(action, presenter: topViewController())
    }

    // Resolves the front-most view controller for presenting deep-link UI/alerts.
    private func topViewController() -> UIViewController? {
        var top = window?.rootViewController
        while true {
            if let presented = top?.presentedViewController {
                top = presented
            } else if let nav = top as? UINavigationController {
                top = nav.visibleViewController ?? nav.topViewController
            } else if let tab = top as? UITabBarController {
                top = tab.selectedViewController
            } else {
                break
            }
        }
        return top
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        aidokuLegacyMarkMemoryPressure()
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyMemoryTrimRequested"), object: nil)
        aidokuLegacyTrimVolatileCaches()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        beginShortBackgroundTask(application)
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyAppDidEnterBackground"), object: nil)
        LegacyModernAutomaticBackupScheduler.shared.createBackupIfNeeded()
        aidokuLegacyTrimVolatileCaches()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyAppWillEnterForeground"), object: nil)
        endShortBackgroundTask(application)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NotificationCenter.default.post(name: Notification.Name("AidokuLegacyAppDidEnterBackground"), object: nil)
        LegacyModernAutomaticBackupScheduler.shared.createBackupIfNeeded()
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
                "AidokuLegacy.reader.upscaleImages": isLegacyIPadAir,
                "AidokuLegacy.reader.prefetchPages": isLegacyIPadAir ? 3 : 2,
                "AidokuLegacy.reader.backgroundColor": "black",
                "AidokuLegacy.reader.showPageNumber": true,
                "AidokuLegacy.reader.showTapZones": true,
                "AidokuLegacy.reader.eInkFlash": false,
                "AidokuLegacy.reader.restoreLastSession": true,
                "AidokuLegacy.appearance.darkTheme": false,
                "AidokuLegacy.library.automaticUpdates": false,
                "AidokuLegacy.sources.automaticUpdates": true,
                "AidokuLegacy.backup.automaticModernBackups": false
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

// Routes a parsed LegacyDeepLinkAction to the existing install / backup / source-list
// / self-hosted / tracker flows. Pure UIKit + Foundation; remote payloads are fetched
// with URLSession completion handlers. Returns true when the action was handled.
enum LegacyDeepLinkCoordinator {
    @discardableResult
    static func handle(_ action: LegacyDeepLinkAction, presenter: UIViewController?) -> Bool {
        switch action {
            case .addSourceList(let url):
                let normalized = LegacySourceRepositoryStore.shared.normalizedURL(from: url.absoluteString) ?? url
                LegacySourceRepositoryStore.shared.add(normalized)
                NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
                presentAlert(
                    on: presenter,
                    title: "Source List Added",
                    message: "Open Sources and refresh to load \(normalized.absoluteString)."
                )
                return true

            case .installPackage(let url):
                installPackage(from: url, presenter: presenter)
                return true

            case .importBackup(let url):
                importBackup(from: url, presenter: presenter)
                return true

            case .addSelfHostedServer:
                // Present the server list so the user can finish entering credentials.
                let serversVC = LegacyKomgaServerListViewController()
                pushOrPresent(serversVC, on: presenter)
                return true

            case .trackerCallback(let token, let code):
                if let token = token, !token.isEmpty {
                    LegacyAniListTracker.shared.setAccessToken(token)
                    NotificationCenter.default.post(name: .aidokuLegacyTrackingDidChange, object: nil)
                    presentAlert(on: presenter, title: "AniList Connected", message: nil)
                    return true
                }
                if let code = code, !code.isEmpty {
                    LegacyMyAnimeListTracker.shared.exchangeCode(code) { result in
                        DispatchQueue.main.async {
                            switch result {
                                case .success:
                                    NotificationCenter.default.post(name: .aidokuLegacyTrackingDidChange, object: nil)
                                    presentAlert(on: presenter, title: "MyAnimeList Connected", message: nil)
                                case .failure(let error):
                                    presentAlert(on: presenter, title: "Login Failed", message: error.localizedDescription)
                            }
                        }
                    }
                    return true
                }
                return false

            case .openManga:
                presentAlert(
                    on: presenter,
                    title: "Unsupported Link",
                    message: "Opening a manga directly from a link is not supported on this version. "
                        + "Search for it in Sources instead."
                )
                return false

            case .unsupported:
                return false
        }
    }

    // MARK: - Package install

    private static func installPackage(from url: URL, presenter: UIViewController?) {
        fetchLocalCopy(of: url, suggestedExtension: "aix") { result in
            switch result {
                case .success(let localURL):
                    do {
                        let installer = AidokuRunnerLegacyPackageInstaller()
                        let source = try installer.installPackage(at: localURL)
                        NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
                        presentAlert(on: presenter, title: "Source Installed", message: source.name)
                    } catch {
                        presentAlert(on: presenter, title: "Install Failed", message: error.localizedDescription)
                    }
                case .failure(let error):
                    presentAlert(on: presenter, title: "Install Failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Backup import

    private static func importBackup(from url: URL, presenter: UIViewController?) {
        fetchLocalCopy(of: url, suggestedExtension: url.pathExtension.isEmpty ? "json" : url.pathExtension) { result in
            switch result {
                case .success(let localURL):
                    // Try the modern format first, then fall back to the legacy JSON restore.
                    LegacyModernBackupImporter.shared.importBackup(at: localURL) { modernResult in
                        DispatchQueue.main.async {
                            switch modernResult {
                                case .success(let summary):
                                    NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
                                    presentAlert(
                                        on: presenter,
                                        title: "Backup Imported",
                                        message: "Added \(summary.libraryAdded) library, \(summary.historyAdded) history, "
                                            + "and \(summary.updatesAdded) update entries."
                                    )
                                case .failure:
                                    do {
                                        try LegacyBackupManager.shared.restore(from: localURL)
                                        NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
                                        presentAlert(on: presenter, title: "Backup Restored", message: nil)
                                    } catch {
                                        presentAlert(on: presenter, title: "Import Failed", message: error.localizedDescription)
                                    }
                            }
                        }
                    }
                case .failure(let error):
                    presentAlert(on: presenter, title: "Import Failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    // Returns a local file URL for the payload: file URLs are copied into a temp
    // location (honouring security scope); remote URLs are downloaded.
    private static func fetchLocalCopy(
        of url: URL,
        suggestedExtension: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if url.isFileURL {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyDeepLink-\(UUID().uuidString).\(suggestedExtension)")
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
            return
        }

        let task = LegacyURLSession.shared.downloadTask(with: url) { tempURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let tempURL = tempURL else {
                completion(.failure(LegacyDeepLinkError.downloadFailed))
                return
            }
            let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyDeepLink-\(UUID().uuidString).\(suggestedExtension)")
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private static func pushOrPresent(_ viewController: UIViewController, on presenter: UIViewController?) {
        if let nav = presenter?.navigationController {
            nav.pushViewController(viewController, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: viewController)
            presenter?.present(nav, animated: true)
        }
    }

    private static func presentAlert(on presenter: UIViewController?, title: String, message: String?) {
        guard let presenter = presenter else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}

private enum LegacyDeepLinkError: Error, LocalizedError {
    case downloadFailed

    var errorDescription: String? {
        switch self {
            case .downloadFailed:
                return "The file could not be downloaded."
        }
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
