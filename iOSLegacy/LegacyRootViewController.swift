//
//  LegacyRootViewController.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit
import WebKit
import ImageIO
import SDWebImage
import SDWebImageWebPCoder
import avif

private let aidokuLegacyImageUserAgent = "Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
private let aidokuLegacyImageAcceptHeader = "image/avif,image/webp,image/*,*/*;q=0.8"
private let aidokuLegacyImageDecodeQueue = DispatchQueue(label: "AidokuLegacy.imageDecode", qos: .utility)
private var aidokuLegacyLastMemoryPressureDate = Date.distantPast

func aidokuLegacyMarkMemoryPressure() {
    aidokuLegacyLastMemoryPressureDate = Date()
}

private func aidokuLegacyHasRecentMemoryPressure() -> Bool {
    return Date().timeIntervalSince(aidokuLegacyLastMemoryPressureDate) < 45
}

private func aidokuLegacyIsLowMemoryMode() -> Bool {
    if UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") {
        return true
    }
    return ProcessInfo.processInfo.physicalMemory <= 1_350_000_000
}

private func aidokuLegacyReaderMaxPixelHeight() -> CGFloat {
    let lowMemoryLimit: CGFloat = aidokuLegacyReaderUpscaleImages() ? 1536 : 768
    let normalLimit: CGFloat = 2200
    let limit = aidokuLegacyIsLowMemoryMode() ? lowMemoryLimit : normalLimit
    let storedValue = UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.maxImageHeight")
    if storedValue > 0 {
        if aidokuLegacyIsLowMemoryMode(), aidokuLegacyReaderUpscaleImages(), storedValue <= 1200 {
            return limit
        }
        return min(CGFloat(storedValue), limit)
    }
    return limit
}

private func aidokuLegacyReaderUpscaleImages() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.upscaleImages")
}

private func aidokuLegacyPrepareReaderImageForDisplay(_ image: UIImage) -> UIImage {
    guard aidokuLegacyReaderUpscaleImages() else { return image }
    let maxPixelHeight = aidokuLegacyReaderMaxPixelHeight()
    let pixelHeight = image.size.height * image.scale
    let pixelWidth = image.size.width * image.scale
    guard pixelHeight > 0, pixelWidth > 0, pixelHeight < maxPixelHeight else {
        return image
    }

    let scale = min(maxPixelHeight / pixelHeight, 1.6)
    guard scale > 1.05 else { return image }
    let targetSize = CGSize(width: max(1, pixelWidth * scale), height: max(1, pixelHeight * scale))

    UIGraphicsBeginImageContextWithOptions(targetSize, false, 1)
    if let context = UIGraphicsGetCurrentContext() {
        context.interpolationQuality = .high
    }
    image.draw(in: CGRect(origin: .zero, size: targetSize))
    let upscaledImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return upscaledImage ?? image
}

private func aidokuLegacyReaderPrefetchCount() -> Int {
    let storedValue = UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.prefetchPages")
    if aidokuLegacyIsLowMemoryMode() {
        if aidokuLegacyHasRecentMemoryPressure() {
            return 0
        }
        return max(1, min(storedValue, 2))
    }
    let bounded = min(max(storedValue, 0), 3)
    return bounded
}

private func aidokuLegacyReaderRetainedPageDelay() -> TimeInterval {
    if aidokuLegacyHasRecentMemoryPressure() {
        return 1.5
    }
    if aidokuLegacyIsLowMemoryMode() {
        return aidokuLegacyReaderUpscaleImages() ? 2.5 : 4
    }
    return 15
}

private func aidokuLegacyReaderShowsPageNumber() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.showPageNumber")
}

private func aidokuLegacyReaderShowsTapZones() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.showTapZones")
}

private func aidokuLegacyApplicationSupportDirectory() throws -> URL {
    guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw NSError(domain: "AidokuLegacy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable."])
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    return directory
}

private func aidokuLegacySanitizedPathComponent(_ value: String) -> String {
    let dot: UnicodeScalar = "."
    let dash: UnicodeScalar = "-"
    let underscore: UnicodeScalar = "_"
    let sanitized = value.unicodeScalars.reduce(into: "") { result, scalar in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == dot || scalar == dash || scalar == underscore {
            result.unicodeScalars.append(scalar)
        } else {
            result.append("_")
        }
    }
    return sanitized.isEmpty ? UUID().uuidString : sanitized
}

private func aidokuLegacyPreparePagesForLowMemory(
    _ pages: [AidokuRunnerLegacyPage]
) -> (pages: [AidokuRunnerLegacyPage], temporaryDirectories: [URL]) {
    guard aidokuLegacyIsLowMemoryMode() else {
        return (pages, [])
    }

    var preparedPages = pages
    var temporaryDirectory: URL?
    for index in preparedPages.indices {
        guard case .image(let data) = preparedPages[index].content else { continue }
        guard !data.isEmpty else { continue }
        if temporaryDirectory == nil {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyInlinePages-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                temporaryDirectory = directory
            } catch {
                continue
            }
        }
        guard let directory = temporaryDirectory else { continue }
        let fileURL = directory.appendingPathComponent("page-\(index).img")
        do {
            try data.write(to: fileURL, options: .atomic)
            preparedPages[index].content = .url(fileURL, context: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    if let temporaryDirectory = temporaryDirectory {
        return (preparedPages, [temporaryDirectory])
    }
    return (preparedPages, [])
}

private func aidokuLegacyRemoveTemporaryPageDirectories(_ directories: [URL]) {
    for directory in directories {
        try? FileManager.default.removeItem(at: directory)
    }
}

private let aidokuLegacyReaderImageSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.timeoutIntervalForRequest = 25
    configuration.timeoutIntervalForResource = 60
    configuration.httpMaximumConnectionsPerHost = aidokuLegacyIsLowMemoryMode() ? 2 : 3
    configuration.urlCache = URLCache(
        memoryCapacity: aidokuLegacyIsLowMemoryMode() ? 256 * 1024 : 6 * 1024 * 1024,
        diskCapacity: aidokuLegacyIsLowMemoryMode() ? 12 * 1024 * 1024 : 48 * 1024 * 1024,
        diskPath: "AidokuLegacyReaderImageCache"
    )
    configuration.httpAdditionalHeaders = [
        "Accept": aidokuLegacyImageAcceptHeader,
        "User-Agent": aidokuLegacyImageUserAgent
    ]
    return URLSession(configuration: configuration)
}()

private final class LegacyReaderImagePipeline {
    static let shared = LegacyReaderImagePipeline()

    private typealias Completion = (UIImage?) -> Void

    private let cache = NSCache<NSString, UIImage>()
    private let stateQueue = DispatchQueue(label: "AidokuLegacy.readerImagePipeline")
    private var waiters: [String: [Completion]] = [:]
    private var memoryObserver: NSObjectProtocol?

    private init() {
        configureCacheLimits()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            aidokuLegacyMarkMemoryPressure()
            self?.clear()
        }
    }

    deinit {
        if let memoryObserver = memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    func clear() {
        stateQueue.async { [weak self] in
            self?.configureCacheLimits()
            self?.cache.removeAllObjects()
        }
    }

    func preload(url: URL, context: [String: String]?, source: AidokuRunnerLegacySource) {
        load(url: url, context: context, source: source) { _ in }
    }

    func load(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        completion: @escaping (UIImage?) -> Void
    ) {
        if url.isFileURL {
            loadLocalFile(url: url, context: context, source: source, completion: completion)
            return
        }

        let cacheKey = self.cacheKey(url: url, context: context, source: source)
        guard startLoad(cacheKey: cacheKey, completion: completion) else { return }
        source.runner.getImageRequest(url: url, context: context) { [weak self] result in
            guard let self = self else { return }
            let request: URLRequest
            switch result {
                case .success(let imageRequest):
                    request = imageRequest.urlRequest(source: source, fallbackURL: url)
                case .failure:
                    request = legacyFallbackImageRequest(url: url, source: source)
            }
            let fallbackRequests = legacyFallbackImageRequests(url: url, source: source, excluding: request)
            self.fetchRemote(
                request: request,
                fallbackRequests: fallbackRequests,
                cacheKey: cacheKey,
                context: context,
                source: source,
                retriesRemaining: 1
            )
        }
    }

    private func loadLocalFile(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        completion: @escaping Completion
    ) {
        let cacheKey = localCacheKey(url: url, context: context, source: source)
        guard startLoad(cacheKey: cacheKey, completion: completion) else { return }
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                return LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            self?.finish(cacheKey: cacheKey, image: image)
        }
    }

    private func fetchRemote(
        request: URLRequest,
        fallbackRequests: [URLRequest],
        cacheKey: String,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        retriesRemaining: Int
    ) {
        aidokuLegacyReaderImageSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode
            if self.shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.fetchRemote(
                        request: request,
                        fallbackRequests: fallbackRequests,
                        cacheKey: cacheKey,
                        context: context,
                        source: source,
                        retriesRemaining: retriesRemaining - 1
                    )
                }
                return
            }

            guard
                let data = data,
                !data.isEmpty,
                let httpResponse = httpResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                self.fetchNextFallback(
                    fallbackRequests,
                    cacheKey: cacheKey,
                    context: context,
                    source: source
                )
                return
            }

            if source.runner.features.processesPages {
                DispatchQueue.main.async {
                    source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { result in
                        switch result {
                            case .success(let image?):
                                self.prepareProcessedImage(image, cacheKey: cacheKey)
                            case .success(nil), .failure:
                                self.decodeImageData(data, cacheKey: cacheKey)
                        }
                    }
                }
            } else {
                self.decodeImageData(data, cacheKey: cacheKey)
            }
        }.resume()
    }

    private func fetchNextFallback(
        _ fallbackRequests: [URLRequest],
        cacheKey: String,
        context: [String: String]?,
        source: AidokuRunnerLegacySource
    ) {
        guard let fallbackRequest = fallbackRequests.first else {
            finish(cacheKey: cacheKey, image: nil)
            return
        }
        let remainingRequests = Array(fallbackRequests.dropFirst())
        fetchRemote(
            request: fallbackRequest,
            fallbackRequests: remainingRequests,
            cacheKey: cacheKey,
            context: context,
            source: source,
            retriesRemaining: 1
        )
    }

    private func prepareProcessedImage(_ image: UIImage, cacheKey: String) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let preparedImage = autoreleasepool {
                aidokuLegacyPrepareReaderImageForDisplay(
                    LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                )
            }
            self?.finish(cacheKey: cacheKey, image: preparedImage)
        }
    }

    private func decodeImageData(_ data: Data, cacheKey: String) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool {
                LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            self?.finish(cacheKey: cacheKey, image: image)
        }
    }

    private func startLoad(cacheKey: String, completion: @escaping Completion) -> Bool {
        let key = cacheKey as NSString
        var cachedImage: UIImage?
        var shouldStart = false
        stateQueue.sync {
            if let image = cache.object(forKey: key) {
                cachedImage = image
            } else if waiters[cacheKey] != nil {
                waiters[cacheKey]?.append(completion)
            } else {
                waiters[cacheKey] = [completion]
                shouldStart = true
            }
        }
        if let cachedImage = cachedImage {
            completion(cachedImage)
        }
        return shouldStart
    }

    private func finish(cacheKey: String, image: UIImage?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if let image = image {
                self.cache.setObject(image, forKey: cacheKey as NSString, cost: self.imageCost(image))
            }
            let callbacks = self.waiters.removeValue(forKey: cacheKey) ?? []
            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    private func shouldRetry(error: Error?, statusCode: Int?, data: Data?) -> Bool {
        if error != nil || data == nil || data?.isEmpty == true {
            return true
        }
        guard let statusCode = statusCode else { return false }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func imageCost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        return max(1, Int(pixels * 4))
    }

    private func configureCacheLimits() {
        if aidokuLegacyIsLowMemoryMode() {
            cache.countLimit = aidokuLegacyReaderUpscaleImages() ? 4 : 5
            cache.totalCostLimit = aidokuLegacyReaderUpscaleImages() ? 16 * 1024 * 1024 : 10 * 1024 * 1024
        } else {
            cache.countLimit = 24
            cache.totalCostLimit = 48 * 1024 * 1024
        }
    }

    private func localCacheKey(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource
    ) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return [
            "file",
            source.key,
            url.path,
            "\(values?.fileSize ?? 0)",
            "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)",
            contextKey(context),
            "\(Int(aidokuLegacyReaderMaxPixelHeight()))",
            aidokuLegacyReaderUpscaleImages() ? "upscale=1" : "upscale=0"
        ].joined(separator: "\n")
    }

    private func cacheKey(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource
    ) -> String {
        return [
            "remote",
            source.key,
            url.absoluteString,
            contextKey(context),
            "\(Int(aidokuLegacyReaderMaxPixelHeight()))",
            aidokuLegacyReaderUpscaleImages() ? "upscale=1" : "upscale=0"
        ].joined(separator: "\n")
    }

    private func contextKey(_ context: [String: String]?) -> String {
        return (context ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }
}

func aidokuLegacyTrimVolatileCaches() {
    LegacyReaderImagePipeline.shared.clear()
    LegacyImageLoader.shared.clear()
    aidokuLegacyReaderImageSession.configuration.urlCache?.removeAllCachedResponses()
    URLCache.shared.removeAllCachedResponses()
    SDImageCache.shared.clearMemory()
}

enum LegacyPalette {
    static var isDarkTheme: Bool {
        return UserDefaults.standard.bool(forKey: "AidokuLegacy.appearance.darkTheme")
    }

    static var background: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
            : UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
    }

    static var panel: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
            : UIColor.white
    }

    static var primaryText: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
            : UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    }

    static var secondaryText: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.68, green: 0.69, blue: 0.72, alpha: 1)
            : UIColor(red: 0.34, green: 0.35, blue: 0.38, alpha: 1)
    }

    static var disabledText: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.43, green: 0.44, blue: 0.47, alpha: 1)
            : UIColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1)
    }

    static let accent = UIColor(red: 0.83, green: 0.12, blue: 0.36, alpha: 1)

    static var barStyle: UIBarStyle {
        return isDarkTheme ? .black : .default
    }
}

private enum LegacyReaderMode: String, CaseIterable {
    case verticalScroll
    case verticalFit
    case pagedLTR
    case pagedRTL

    static let defaultsKey = "AidokuLegacy.reader.mode"

    static var current: LegacyReaderMode {
        if
            let rawValue = persistedRawValue,
            let mode = LegacyReaderMode(rawValue: rawValue)
        {
            return mode
        }
        return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.fitToScreen") ? .verticalFit : .verticalScroll
    }

    static func setCurrent(_ mode: LegacyReaderMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        UserDefaults.standard.set(mode != .verticalScroll, forKey: "AidokuLegacy.reader.fitToScreen")
    }

    private static var persistedRawValue: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return UserDefaults.standard.string(forKey: defaultsKey)
        }
        return UserDefaults.standard.persistentDomain(forName: bundleID)?[defaultsKey] as? String
    }

    var title: String {
        switch self {
            case .verticalScroll:
                return "Vertical Scroll"
            case .verticalFit:
                return "Vertical Fit to Screen"
            case .pagedLTR:
                return "Paged Left to Right"
            case .pagedRTL:
                return "Paged Right to Left"
        }
    }

    var detail: String {
        switch self {
            case .verticalScroll:
                return "Continuous scrolling with page-height images"
            case .verticalFit:
                return "Each page fits within the visible screen"
            case .pagedLTR:
                return "Horizontal pages; swipe left for the next page"
            case .pagedRTL:
                return "Horizontal pages; swipe right for the next page"
        }
    }

    var usesPagedReader: Bool {
        switch self {
            case .pagedLTR, .pagedRTL:
                return true
            case .verticalScroll, .verticalFit:
                return false
        }
    }

}

private extension Notification.Name {
    static let legacyInstalledSourcesDidChange = Notification.Name("AidokuLegacyInstalledSourcesDidChange")
    static let legacyLibraryDidChange = Notification.Name("AidokuLegacyLibraryDidChange")
    static let legacyHistoryDidChange = Notification.Name("AidokuLegacyHistoryDidChange")
    static let legacyAppearanceDidChange = Notification.Name("AidokuLegacyAppearanceDidChange")
    static let legacyDownloadsDidChange = Notification.Name("AidokuLegacyDownloadsDidChange")
    static let legacyUpdatesDidChange = Notification.Name("AidokuLegacyUpdatesDidChange")
    static let legacyAppDidEnterBackground = Notification.Name("AidokuLegacyAppDidEnterBackground")
    static let legacyAppWillEnterForeground = Notification.Name("AidokuLegacyAppWillEnterForeground")
    static let legacyMemoryTrimRequested = Notification.Name("AidokuLegacyMemoryTrimRequested")
}

final class LegacyTabBarController: UITabBarController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var appearanceObserver: NSObjectProtocol?
    private var didAttemptReaderRestore = false
    private var didStartAutomaticSourceUpdate = false

    override func viewDidLoad() {
        super.viewDidLoad()

        let library = UINavigationController(rootViewController: LegacyLibraryViewController())
        library.tabBarItem = UITabBarItem(tabBarSystemItem: .favorites, tag: 0)
        library.tabBarItem.title = "Library"

        let history = UINavigationController(rootViewController: LegacyHistoryViewController())
        history.tabBarItem = UITabBarItem(tabBarSystemItem: .history, tag: 1)
        history.tabBarItem.title = "History"

        let sources = UINavigationController(rootViewController: LegacyInstalledSourcesViewController())
        sources.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: 2)
        sources.tabBarItem.title = "Sources"

        let browse = UINavigationController(rootViewController: LegacyRootViewController())
        browse.tabBarItem = UITabBarItem(tabBarSystemItem: .downloads, tag: 3)
        browse.tabBarItem.title = "Browse"

        let settings = UINavigationController(rootViewController: LegacySettingsViewController())
        settings.tabBarItem = UITabBarItem(tabBarSystemItem: .more, tag: 4)
        settings.tabBarItem.title = "Settings"

        viewControllers = [library, history, sources, browse, settings]
        selectedIndex = LegacyLibraryStore.shared.entries.isEmpty ? 2 : 0
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .legacyAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreLastReaderIfNeeded()
        updateInstalledSourcesIfNeeded()
    }

    deinit {
        if let appearanceObserver = appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    private func applyAppearance() {
        view.backgroundColor = LegacyPalette.background
        tabBar.tintColor = LegacyPalette.accent
        tabBar.barStyle = LegacyPalette.barStyle
        tabBar.barTintColor = LegacyPalette.panel
        viewControllers?.forEach { controller in
            guard let navigationController = controller as? UINavigationController else { return }
            navigationController.navigationBar.tintColor = LegacyPalette.accent
            navigationController.navigationBar.barStyle = LegacyPalette.barStyle
            navigationController.navigationBar.barTintColor = LegacyPalette.panel
            navigationController.navigationBar.titleTextAttributes = [.foregroundColor: LegacyPalette.primaryText]
            if #available(iOS 11.0, *) {
                navigationController.navigationBar.largeTitleTextAttributes = [.foregroundColor: LegacyPalette.primaryText]
            }
            if let tableController = navigationController.topViewController as? UITableViewController {
                tableController.view.backgroundColor = LegacyPalette.background
                tableController.tableView.backgroundColor = LegacyPalette.background
                tableController.tableView.reloadData()
            }
        }
    }

    private func restoreLastReaderIfNeeded() {
        guard !didAttemptReaderRestore else { return }
        didAttemptReaderRestore = true
        guard UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.restoreLastSession") else { return }
        guard let entry = LegacyReaderSessionStore.shared.entry else { return }
        guard Date().timeIntervalSince(entry.dateRead) < 7 * 24 * 60 * 60 else { return }
        let sources = packageInstaller.loadInstalledSources()
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else { return }
        guard let navigationController = viewControllers?[1] as? UINavigationController else { return }
        selectedIndex = 1
        navigationController.popToRootViewController(animated: false)
        navigationController.pushViewController(
            LegacyReaderFactory.makeReader(
                source: source,
                manga: entry.manga,
                chapter: entry.chapter,
                initialPageIndex: entry.pageIndex
            ),
            animated: false
        )
    }

    private func updateInstalledSourcesIfNeeded() {
        guard !didStartAutomaticSourceUpdate else { return }
        didStartAutomaticSourceUpdate = true
        LegacySourceUpdateManager.shared.updateInstalledSourcesIfNeeded(automatic: true)
    }
}

enum LegacyLibrarySortOption: String, CaseIterable {
    case recentlyAdded
    case title
    case source

    private static let defaultsKey = "AidokuLegacy.library.sortOption"

    static var current: LegacyLibrarySortOption {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let option = LegacyLibrarySortOption(rawValue: rawValue)
        else {
            return .recentlyAdded
        }
        return option
    }

    static func setCurrent(_ option: LegacyLibrarySortOption) {
        UserDefaults.standard.set(option.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
            case .recentlyAdded:
                return "Recently Added"
            case .title:
                return "Title"
            case .source:
                return "Source"
        }
    }
}

private extension AidokuRunnerLegacyManga {
    func mergedWithUpdate(_ update: AidokuRunnerLegacyManga) -> AidokuRunnerLegacyManga {
        var manga = update
        if manga.sourceKey.isEmpty {
            manga.sourceKey = sourceKey
        }
        if manga.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manga.title = title
        }
        manga.cover = Self.nonEmpty(manga.cover) ?? Self.nonEmpty(cover)
        manga.artists = manga.artists ?? artists
        manga.authors = manga.authors ?? authors
        manga.description = manga.description ?? description
        manga.url = manga.url ?? url
        manga.tags = manga.tags ?? tags
        manga.chapters = manga.chapters ?? chapters
        return manga
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct LegacyLibraryEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var dateAdded: Date
    var category: String?

    var key: String {
        return "\(sourceKey)::\(manga.key)"
    }
}

final class LegacyLibraryStore {
    static let shared = LegacyLibraryStore()

    private let defaultsKey = "AidokuLegacy.library.entries"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var entries: [LegacyLibraryEntry] {
        return entries(sort: .recentlyAdded)
    }

    var rawEntries: [LegacyLibraryEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyLibraryEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    func entries(category: String? = nil, query: String? = nil, sort: LegacyLibrarySortOption = .recentlyAdded) -> [LegacyLibraryEntry] {
        var filteredEntries = rawEntries
        if let category = category {
            if category.isEmpty {
                filteredEntries = filteredEntries.filter { ($0.category ?? "").isEmpty }
            } else {
                filteredEntries = filteredEntries.filter { $0.category == category }
            }
        }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuery.isEmpty {
            filteredEntries = filteredEntries.filter {
                $0.manga.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.sourceName.localizedCaseInsensitiveContains(trimmedQuery)
                    || ($0.category?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
            }
        }
        return sortEntries(filteredEntries, sort: sort)
    }

    func categories() -> [String] {
        let values = rawEntries.compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func contains(sourceKey: String, mangaKey: String) -> Bool {
        return rawEntries.contains { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    func entry(sourceKey: String, mangaKey: String) -> LegacyLibraryEntry? {
        return rawEntries.first { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    func add(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = rawEntries.filter { !($0.sourceKey == source.key && $0.manga.key == manga.key) }
        current.insert(
            LegacyLibraryEntry(sourceKey: source.key, sourceName: source.name, manga: manga, dateAdded: Date(), category: nil),
            at: 0
        )
        save(current)
    }

    func update(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = rawEntries
        guard let index = current.firstIndex(where: { $0.sourceKey == source.key && $0.manga.key == manga.key }) else {
            return
        }
        let mergedManga = current[index].manga.mergedWithUpdate(manga)
        current[index] = LegacyLibraryEntry(
            sourceKey: source.key,
            sourceName: source.name,
            manga: mergedManga,
            dateAdded: current[index].dateAdded,
            category: current[index].category
        )
        save(current)
    }

    func updateMangaMetadata(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = rawEntries
        var didChange = false
        for index in current.indices where current[index].sourceKey == source.key && current[index].manga.key == manga.key {
            let mergedManga = current[index].manga.mergedWithUpdate(manga)
            if mergedManga != current[index].manga {
                current[index].manga = mergedManga
                current[index].sourceName = source.name
                didChange = true
            }
        }
        if didChange {
            save(current)
        }
    }

    func setCategory(sourceKey: String, mangaKey: String, category: String?) {
        var current = rawEntries
        guard let index = current.firstIndex(where: { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }) else {
            return
        }
        let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        current[index].category = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save(current)
    }

    func remove(sourceKey: String, mangaKey: String) {
        save(rawEntries.filter { !($0.sourceKey == sourceKey && $0.manga.key == mangaKey) })
    }

    func clear() {
        save([])
    }

    func replace(_ entries: [LegacyLibraryEntry]) {
        save(entries)
    }

    private func entries(sort: LegacyLibrarySortOption) -> [LegacyLibraryEntry] {
        return sortEntries(rawEntries, sort: sort)
    }

    private func sortEntries(_ entries: [LegacyLibraryEntry], sort: LegacyLibrarySortOption) -> [LegacyLibraryEntry] {
        switch sort {
            case .recentlyAdded:
                return entries.sorted { $0.dateAdded > $1.dateAdded }
            case .title:
                return entries.sorted { $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title) == .orderedAscending }
            case .source:
                return entries.sorted {
                    let sourceCompare = $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName)
                    if sourceCompare != .orderedSame {
                        return sourceCompare == .orderedAscending
                    }
                    return $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title) == .orderedAscending
                }
        }
    }

    private func save(_ entries: [LegacyLibraryEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
        }
    }
}

struct LegacyHistoryEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
    var pageIndex: Int
    var pageCount: Int
    var dateRead: Date

    var key: String {
        return "\(sourceKey)::\(manga.key)::\(chapter.key)"
    }
}

final class LegacyHistoryStore {
    static let shared = LegacyHistoryStore()

    private let defaultsKey = "AidokuLegacy.history.entries"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var entries: [LegacyHistoryEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyHistoryEntry].self, from: data)
        else {
            return []
        }
        return entries.sorted { $0.dateRead > $1.dateRead }
    }

    func update(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        pageIndex: Int,
        pageCount: Int
    ) {
        let key = "\(source.key)::\(manga.key)::\(chapter.key)"
        let currentEntries = entries
        var mergedManga = manga
        if let libraryManga = LegacyLibraryStore.shared.entry(sourceKey: source.key, mangaKey: manga.key)?.manga {
            mergedManga = libraryManga.mergedWithUpdate(mergedManga)
        }
        if let existingManga = currentEntries.first(where: { $0.sourceKey == source.key && $0.manga.key == manga.key })?.manga {
            mergedManga = existingManga.mergedWithUpdate(mergedManga)
        }
        var current = currentEntries.filter { $0.key != key }
        current.insert(
            LegacyHistoryEntry(
                sourceKey: source.key,
                sourceName: source.name,
                manga: mergedManga,
                chapter: chapter,
                pageIndex: max(0, pageIndex),
                pageCount: max(pageCount, 0),
                dateRead: Date()
            ),
            at: 0
        )
        save(Array(current.prefix(250)))
    }

    func remove(key: String) {
        save(entries.filter { $0.key != key })
    }

    func removeManga(sourceKey: String, mangaKey: String) {
        save(entries.filter { !($0.sourceKey == sourceKey && $0.manga.key == mangaKey) })
    }

    func latest(sourceKey: String, mangaKey: String) -> LegacyHistoryEntry? {
        return entries.first { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    func updateMangaMetadata(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = entries
        var didChange = false
        for index in current.indices where current[index].sourceKey == source.key && current[index].manga.key == manga.key {
            let mergedManga = current[index].manga.mergedWithUpdate(manga)
            if mergedManga != current[index].manga {
                current[index].manga = mergedManga
                current[index].sourceName = source.name
                didChange = true
            }
        }
        if didChange {
            save(current)
        }
    }

    func clear() {
        save([])
    }

    func replace(_ entries: [LegacyHistoryEntry]) {
        save(entries)
    }

    private func save(_ entries: [LegacyHistoryEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyHistoryDidChange, object: nil)
        }
    }
}

final class LegacyReaderSessionStore {
    static let shared = LegacyReaderSessionStore()

    private let defaultsKey = "AidokuLegacy.reader.lastSession"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var entry: LegacyHistoryEntry? {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entry = try? decoder.decode(LegacyHistoryEntry.self, from: data)
        else {
            return nil
        }
        return entry
    }

    func save(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        pageIndex: Int,
        pageCount: Int
    ) {
        let entry = LegacyHistoryEntry(
            sourceKey: source.key,
            sourceName: source.name,
            manga: manga,
            chapter: chapter,
            pageIndex: max(0, pageIndex),
            pageCount: max(pageCount, 0),
            dateRead: Date()
        )
        if let data = try? encoder.encode(entry) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

struct LegacyUpdateEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
    var dateFound: Date

    var key: String {
        return "\(sourceKey)::\(manga.key)::\(chapter.key)"
    }
}

final class LegacyUpdateStore {
    static let shared = LegacyUpdateStore()

    private let defaultsKey = "AidokuLegacy.updates.entries"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var entries: [LegacyUpdateEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyUpdateEntry].self, from: data)
        else {
            return []
        }
        return entries.sorted { $0.dateFound > $1.dateFound }
    }

    func add(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga, chapters: [AidokuRunnerLegacyChapter]) {
        guard !chapters.isEmpty else { return }
        var current = entries
        let now = Date()
        for chapter in chapters {
            let entry = LegacyUpdateEntry(
                sourceKey: source.key,
                sourceName: source.name,
                manga: manga,
                chapter: chapter,
                dateFound: now
            )
            current.removeAll { $0.key == entry.key }
            current.insert(entry, at: 0)
        }
        save(Array(current.prefix(500)))
    }

    func updateMangaMetadata(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = entries
        var didChange = false
        for index in current.indices where current[index].sourceKey == source.key && current[index].manga.key == manga.key {
            let mergedManga = current[index].manga.mergedWithUpdate(manga)
            if mergedManga != current[index].manga {
                current[index].manga = mergedManga
                current[index].sourceName = source.name
                didChange = true
            }
        }
        if didChange {
            save(current)
        }
    }

    func remove(key: String) {
        save(entries.filter { $0.key != key })
    }

    func clear() {
        save([])
    }

    func replace(_ entries: [LegacyUpdateEntry]) {
        save(entries)
    }

    private func save(_ entries: [LegacyUpdateEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyUpdatesDidChange, object: nil)
        }
    }
}

struct LegacyDownloadedChapter: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
    var pageCount: Int
    var byteCount: Int64
    var dateDownloaded: Date

    var key: String {
        return "\(sourceKey)::\(manga.key)::\(chapter.key)"
    }
}

private struct LegacyDownloadedPageRecord: Codable {
    enum Kind: String, Codable {
        case image
        case text
    }

    var kind: Kind
    var fileName: String?
    var text: String?
    var description: String?
}

private struct LegacyDownloadedChapterManifest: Codable {
    var chapter: LegacyDownloadedChapter
    var pages: [LegacyDownloadedPageRecord]
}

final class LegacyDownloadStore {
    static let shared = LegacyDownloadStore()

    private let fileManager = FileManager.default
    private let manifestFileName = "manifest.json"

    var downloadedChapters: [LegacyDownloadedChapter] {
        guard
            let root = try? downloadsDirectory(),
            let manifests = try? fileManager.subpathsOfDirectory(atPath: root.path)
        else {
            return []
        }
        return manifests
            .filter { $0.hasSuffix(manifestFileName) }
            .compactMap { relativePath -> LegacyDownloadedChapter? in
                let url = root.appendingPathComponent(relativePath)
                guard
                    let data = try? Data(contentsOf: url),
                    let manifest = try? JSONDecoder().decode(LegacyDownloadedChapterManifest.self, from: data)
                else {
                    return nil
                }
                return manifest.chapter
            }
            .sorted { $0.dateDownloaded > $1.dateDownloaded }
    }

    func hasChapter(sourceKey: String, mangaKey: String, chapterKey: String) -> Bool {
        let directory = chapterDirectory(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
        return fileManager.fileExists(atPath: directory.appendingPathComponent(manifestFileName).path)
    }

    func pages(sourceKey: String, mangaKey: String, chapterKey: String) -> [AidokuRunnerLegacyPage]? {
        let directory = chapterDirectory(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(LegacyDownloadedChapterManifest.self, from: data)
        else {
            return nil
        }
        let pages: [AidokuRunnerLegacyPage] = manifest.pages.compactMap { record in
            switch record.kind {
                case .text:
                    return AidokuRunnerLegacyPage(
                        content: .text(record.text ?? ""),
                        hasDescription: !(record.description ?? "").isEmpty,
                        description: record.description
                    )
                case .image:
                    guard
                        let fileName = record.fileName
                    else {
                        return nil
                    }
                    return AidokuRunnerLegacyPage(
                        content: .url(directory.appendingPathComponent(fileName), context: nil),
                        hasDescription: !(record.description ?? "").isEmpty,
                        description: record.description
                    )
            }
        }
        return pages.count == manifest.pages.count ? pages : nil
    }

    func makeWriter(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        pageCount: Int
    ) throws -> LegacyDownloadWriter {
        return try LegacyDownloadWriter(
            store: self,
            source: source,
            manga: manga,
            chapter: chapter,
            pageCount: pageCount
        )
    }

    func delete(_ chapter: LegacyDownloadedChapter) {
        let directory = chapterDirectory(sourceKey: chapter.sourceKey, mangaKey: chapter.manga.key, chapterKey: chapter.chapter.key)
        try? fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
    }

    func delete(sourceKey: String, mangaKey: String, chapterKey: String) {
        let directory = chapterDirectory(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
        try? fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
    }

    func clear() {
        if let directory = try? downloadsDirectory() {
            try? fileManager.removeItem(at: directory)
        }
        NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
    }

    fileprivate func downloadsDirectory() throws -> URL {
        let directory = try aidokuLegacyApplicationSupportDirectory()
            .appendingPathComponent("AidokuLegacyDownloads", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    fileprivate func chapterDirectory(sourceKey: String, mangaKey: String, chapterKey: String) -> URL {
        let root = (try? downloadsDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(sourceKey), isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(mangaKey), isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(chapterKey), isDirectory: true)
    }

    final class LegacyDownloadWriter {
        private let store: LegacyDownloadStore
        private let fileManager = FileManager.default
        private let finalDirectory: URL
        private let tempDirectory: URL
        private let chapterInfo: LegacyDownloadedChapter
        private var records: [LegacyDownloadedPageRecord] = []
        private var byteCount: Int64 = 0

        fileprivate init(
            store: LegacyDownloadStore,
            source: AidokuRunnerLegacySource,
            manga: AidokuRunnerLegacyManga,
            chapter: AidokuRunnerLegacyChapter,
            pageCount: Int
        ) throws {
            self.store = store
            finalDirectory = store.chapterDirectory(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key)
            tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyDownload-\(UUID().uuidString)", isDirectory: true)
            chapterInfo = LegacyDownloadedChapter(
                sourceKey: source.key,
                sourceName: source.name,
                manga: manga,
                chapter: chapter,
                pageCount: pageCount,
                byteCount: 0,
                dateDownloaded: Date()
            )
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        func writeImageData(_ data: Data, index: Int, description: String?) throws {
            let fileName = String(format: "%04d.img", index)
            try data.write(to: tempDirectory.appendingPathComponent(fileName), options: .atomic)
            byteCount += Int64(data.count)
            records.append(LegacyDownloadedPageRecord(kind: .image, fileName: fileName, text: nil, description: description))
        }

        func writeText(_ text: String, description: String?) {
            records.append(LegacyDownloadedPageRecord(kind: .text, fileName: nil, text: text, description: description))
            byteCount += Int64(text.utf8.count)
        }

        func finish() throws -> LegacyDownloadedChapter {
            var finishedChapter = chapterInfo
            finishedChapter.byteCount = byteCount
            finishedChapter.pageCount = records.count
            let manifest = LegacyDownloadedChapterManifest(chapter: finishedChapter, pages: records)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: tempDirectory.appendingPathComponent(store.manifestFileName), options: .atomic)
            try? fileManager.removeItem(at: finalDirectory)
            try fileManager.createDirectory(at: finalDirectory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try fileManager.moveItem(at: tempDirectory, to: finalDirectory)
            NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
            return finishedChapter
        }

        func cancel() {
            try? fileManager.removeItem(at: tempDirectory)
        }
    }
}

final class LegacyDownloadManager {
    static let shared = LegacyDownloadManager()

    private init() {}

    private enum DownloadPageRequest {
        case request(URLRequest)
        case localFile(URL)
    }

    func download(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        if LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            let existing = LegacyDownloadStore.shared.downloadedChapters.first {
                $0.sourceKey == source.key && $0.manga.key == manga.key && $0.chapter.key == chapter.key
            }
            if let existing = existing {
                completion(.success(existing))
                return
            }
        }
        source.runner.getPageList(manga: manga, chapter: chapter) { result in
            switch result {
                case .success(let pages):
                    guard !pages.isEmpty else {
                        completion(.failure(NSError(domain: "AidokuLegacy", code: 2, userInfo: [NSLocalizedDescriptionKey: "No pages to download."])))
                        return
                    }
                    do {
                        let writer = try LegacyDownloadStore.shared.makeWriter(
                            source: source,
                            manga: manga,
                            chapter: chapter,
                            pageCount: pages.count
                        )
                        self.downloadPage(
                            pages: pages,
                            index: 0,
                            source: source,
                            writer: writer,
                            progress: progress,
                            completion: completion
                        )
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    private func downloadPage(
        pages: [AidokuRunnerLegacyPage],
        index: Int,
        source: AidokuRunnerLegacySource,
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        guard pages.indices.contains(index) else {
            do {
                completion(.success(try writer.finish()))
            } catch {
                writer.cancel()
                completion(.failure(error))
            }
            return
        }
        autoreleasepool {
            let page = pages[index]
            progress(index + 1, pages.count)
            switch page.content {
                case .image(let data):
                    do {
                        try writer.writeImageData(data, index: index, description: page.description)
                        self.downloadPage(pages: pages, index: index + 1, source: source, writer: writer, progress: progress, completion: completion)
                    } catch {
                        writer.cancel()
                        completion(.failure(error))
                    }
                case .text(let text):
                    writer.writeText(text, description: page.description)
                    self.downloadPage(pages: pages, index: index + 1, source: source, writer: writer, progress: progress, completion: completion)
                case .zipFile(_, _):
                    writer.writeText("ZIP pages are not supported in the legacy downloader yet.", description: page.description)
                    self.downloadPage(pages: pages, index: index + 1, source: source, writer: writer, progress: progress, completion: completion)
                case .url(let url, let context):
                    if url.isFileURL {
                        self.fetchDownloadedPage(
                            request: .localFile(url),
                            context: context,
                            source: source,
                            pageDescription: page.description,
                            pageIndex: index,
                            pages: pages,
                            writer: writer,
                            progress: progress,
                            completion: completion
                        )
                        return
                    }
                    source.runner.getImageRequest(url: url, context: context) { result in
                        let pageRequest: URLRequest
                        switch result {
                            case .success(let imageRequest):
                                pageRequest = imageRequest.urlRequest(source: source, fallbackURL: url)
                            case .failure:
                                pageRequest = legacyFallbackImageRequest(url: url, source: source)
                        }
                        self.fetchDownloadedPage(
                            request: .request(pageRequest),
                            context: context,
                            source: source,
                            pageDescription: page.description,
                            pageIndex: index,
                            pages: pages,
                            writer: writer,
                            progress: progress,
                            completion: completion
                        )
                    }
            }
        }
    }

    private func fetchDownloadedPage(
        request: DownloadPageRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        switch request {
            case .localFile(let url):
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = try? Data(contentsOf: url)
                    guard let data = data, !data.isEmpty else {
                        writer.cancel()
                        completion(.failure(NSError(domain: "AidokuLegacy", code: 4, userInfo: [NSLocalizedDescriptionKey: "Downloaded page \(pageIndex + 1) is missing."])))
                        return
                    }
                    self.writeDownloadedPageData(
                        data,
                        pageDescription: pageDescription,
                        pageIndex: pageIndex,
                        pages: pages,
                        source: source,
                        writer: writer,
                        progress: progress,
                        completion: completion
                    )
                }
                return
            case .request(let urlRequest):
                fetchRemoteDownloadedPage(
                    request: urlRequest,
                    context: context,
                    source: source,
                    pageDescription: pageDescription,
                    pageIndex: pageIndex,
                    pages: pages,
                    writer: writer,
                    progress: progress,
                    completion: completion
                )
        }
    }

    private func fetchRemoteDownloadedPage(
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        aidokuLegacyReaderImageSession.dataTask(with: request) { data, response, error in
            if let error = error {
                writer.cancel()
                completion(.failure(error))
                return
            }
            guard
                let data = data,
                !data.isEmpty,
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                writer.cancel()
                completion(.failure(NSError(domain: "AidokuLegacy", code: 3, userInfo: [NSLocalizedDescriptionKey: "Page \(pageIndex + 1) failed to download."])))
                return
            }
            if source.runner.features.processesPages {
                source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { result in
                    let outputData: Data
                    if case .success(let image?) = result {
                        let maxHeight = aidokuLegacyReaderMaxPixelHeight()
                        let preparedImage = autoreleasepool {
                            LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                        }
                        outputData = preparedImage.jpegData(compressionQuality: 0.92) ?? preparedImage.pngData() ?? data
                    } else {
                        outputData = data
                    }
                    self.writeDownloadedPageData(
                        outputData,
                        pageDescription: pageDescription,
                        pageIndex: pageIndex,
                        pages: pages,
                        source: source,
                        writer: writer,
                        progress: progress,
                        completion: completion
                    )
                }
            } else {
                self.writeDownloadedPageData(
                    data,
                    pageDescription: pageDescription,
                    pageIndex: pageIndex,
                    pages: pages,
                    source: source,
                    writer: writer,
                    progress: progress,
                    completion: completion
                )
            }
        }.resume()
    }

    private func writeDownloadedPageData(
        _ data: Data,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        source: AidokuRunnerLegacySource,
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        do {
            try writer.writeImageData(data, index: pageIndex, description: pageDescription)
            self.downloadPage(pages: pages, index: pageIndex + 1, source: source, writer: writer, progress: progress, completion: completion)
        } catch {
            writer.cancel()
            completion(.failure(error))
        }
    }
}

private struct LegacyBackupFile: Codable {
    var version: Int
    var createdAt: Date
    var library: [LegacyLibraryEntry]
    var history: [LegacyHistoryEntry]
    var updates: [LegacyUpdateEntry]
    var repositories: [String]
    var settings: [LegacyBackupSetting]
}

private struct LegacyBackupSetting: Codable {
    var key: String
    var boolValue: Bool?
    var intValue: Int?
    var doubleValue: Double?
    var stringValue: String?
    var stringArrayValue: [String]?
}

final class LegacyBackupManager {
    static let shared = LegacyBackupManager()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func createBackup() throws -> URL {
        let backup = LegacyBackupFile(
            version: 1,
            createdAt: Date(),
            library: LegacyLibraryStore.shared.rawEntries,
            history: LegacyHistoryStore.shared.entries,
            updates: LegacyUpdateStore.shared.entries,
            repositories: LegacySourceRepositoryStore.shared.repositoryURLs.map { $0.absoluteString },
            settings: collectSettings()
        )
        let directory = try backupDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("AidokuLegacy-\(formatter.string(from: Date())).json")
        try encoder.encode(backup).write(to: url, options: .atomic)
        return url
    }

    func restore(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let backup = try decoder.decode(LegacyBackupFile.self, from: data)
        LegacyLibraryStore.shared.replace(backup.library)
        LegacyHistoryStore.shared.replace(backup.history)
        LegacyUpdateStore.shared.replace(backup.updates)
        LegacySourceRepositoryStore.shared.replace(with: backup.repositories.compactMap(URL.init(string:)))
        applySettings(backup.settings)
    }

    func backupURLs() -> [URL] {
        guard
            let directory = try? backupDirectory(),
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return lhsDate > rhsDate
            }
    }

    private func backupDirectory() throws -> URL {
        let directory = try aidokuLegacyApplicationSupportDirectory()
            .appendingPathComponent("AidokuLegacyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func collectSettings() -> [LegacyBackupSetting] {
        return UserDefaults.standard.dictionaryRepresentation().compactMap { key, value in
            guard shouldBackupSetting(key: key) else { return nil }
            if let value = value as? Bool {
                return LegacyBackupSetting(key: key, boolValue: value, intValue: nil, doubleValue: nil, stringValue: nil, stringArrayValue: nil)
            }
            if let value = value as? Int {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: value, doubleValue: nil, stringValue: nil, stringArrayValue: nil)
            }
            if let value = value as? Double {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: nil, doubleValue: value, stringValue: nil, stringArrayValue: nil)
            }
            if let value = value as? String {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: nil, doubleValue: nil, stringValue: value, stringArrayValue: nil)
            }
            if let value = value as? [String] {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: nil, doubleValue: nil, stringValue: nil, stringArrayValue: value)
            }
            return nil
        }
    }

    private func shouldBackupSetting(key: String) -> Bool {
        if key == "AidokuLegacy.library.entries" || key == "AidokuLegacy.history.entries" || key == "AidokuLegacy.updates.entries" {
            return false
        }
        if key.hasPrefix("AidokuLegacy.") {
            return true
        }
        return key.hasSuffix(".languages") || key.hasSuffix(".language") || key.hasSuffix(".url")
    }

    private func applySettings(_ settings: [LegacyBackupSetting]) {
        for setting in settings {
            if let value = setting.boolValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.intValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.doubleValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.stringValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.stringArrayValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            }
        }
        NotificationCenter.default.post(name: .legacyAppearanceDidChange, object: nil)
        NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
    }
}

final class LegacyImageLoader {
    static let shared = LegacyImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var memoryObserver: NSObjectProtocol?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 25
        configuration.httpMaximumConnectionsPerHost = aidokuLegacyIsLowMemoryMode() ? 1 : 3
        configuration.urlCache = URLCache(
            memoryCapacity: aidokuLegacyIsLowMemoryMode() ? 128 * 1024 : 6 * 1024 * 1024,
            diskCapacity: aidokuLegacyIsLowMemoryMode() ? 4 * 1024 * 1024 : 48 * 1024 * 1024,
            diskPath: "AidokuLegacyCoverImageCache"
        )
        configuration.httpAdditionalHeaders = [
            "Accept": aidokuLegacyImageAcceptHeader,
            "User-Agent": aidokuLegacyImageUserAgent
        ]
        session = URLSession(configuration: configuration)
        cache.countLimit = aidokuLegacyIsLowMemoryMode() ? 8 : 120
        cache.totalCostLimit = aidokuLegacyIsLowMemoryMode() ? 1024 * 1024 : 28 * 1024 * 1024
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clear()
        }
    }

    func clear() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func removeCachedImage(for url: URL, source: AidokuRunnerLegacySource? = nil) {
        cache.removeObject(forKey: url as NSURL)
        let requests = [legacyFallbackImageRequest(url: url, source: source)]
            + legacyFallbackImageRequests(url: url, source: source)
        for request in requests {
            session.configuration.urlCache?.removeCachedResponse(for: request)
        }
    }

    func removeCachedImages(for urls: [URL], source: AidokuRunnerLegacySource? = nil) {
        for url in urls {
            removeCachedImage(for: url, source: source)
        }
    }

    @discardableResult
    func load(
        url: URL,
        source: AidokuRunnerLegacySource? = nil,
        targetHeight: CGFloat = 220,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return nil
        }

        if url.isFileURL {
            loadLocalFile(url: url, cacheKey: key, targetHeight: targetHeight, completion: completion)
            return nil
        }

        if let source = source {
            source.runner.getImageRequest(url: url, context: nil) { [weak self] result in
                let request: URLRequest
                switch result {
                    case .success(let imageRequest):
                        request = imageRequest.urlRequest(source: source, fallbackURL: url)
                    case .failure:
                        request = legacyFallbackImageRequest(url: url, source: source)
                }
                self?.load(
                    request: request,
                    cacheKey: key,
                    targetHeight: targetHeight,
                    forceDownsample: true,
                    fallbackRequests: legacyFallbackImageRequests(url: url, source: source, excluding: request),
                    completion: completion
                )
            }
            return nil
        }

        return load(
            request: legacyFallbackImageRequest(url: url),
            cacheKey: key,
            targetHeight: targetHeight,
            forceDownsample: true,
            fallbackRequests: legacyFallbackImageRequests(url: url, source: nil),
            completion: completion
        )
    }

    @discardableResult
    func loadCover(
        urls: [URL],
        source: AidokuRunnerLegacySource,
        targetHeight: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask? {
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            if !result.contains(url) {
                result.append(url)
            }
        }
        guard let firstURL = uniqueURLs.first else {
            completion(nil)
            return nil
        }
        let cacheKey = firstURL as NSURL
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return nil
        }
        if firstURL.isFileURL {
            loadLocalFile(url: firstURL, cacheKey: cacheKey, targetHeight: targetHeight, completion: completion)
            return nil
        }

        let fallbackRequests = uniqueURLs.flatMap { legacyFallbackImageRequests(url: $0, source: source) }
        source.runner.getImageRequest(url: firstURL, context: nil) { [weak self] result in
            let request: URLRequest
            switch result {
                case .success(let imageRequest):
                    request = imageRequest.urlRequest(source: source, fallbackURL: firstURL)
                case .failure:
                    request = legacyFallbackImageRequest(url: firstURL, source: source)
            }
            self?.load(
                request: request,
                cacheKey: cacheKey,
                targetHeight: targetHeight,
                forceDownsample: true,
                fallbackRequests: fallbackRequests.filter { !legacyImageRequestsMatch($0, request) },
                completion: completion
            )
        }
        return nil
    }

    private func loadLocalFile(
        url: URL,
        cacheKey key: NSURL,
        targetHeight: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let image = (try? Data(contentsOf: url)).flatMap { data -> UIImage? in
                return autoreleasepool {
                    self?.makeImage(
                        from: data,
                        maxPixelHeight: targetHeight * UIScreen.main.scale,
                        forceDownsample: true
                    )
                }
            }
            if let image = image {
                self?.store(image, forKey: key)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    @discardableResult
    private func load(
        request: URLRequest,
        cacheKey key: NSURL,
        targetHeight: CGFloat,
        forceDownsample: Bool,
        fallbackRequests: [URLRequest] = [],
        retriesRemaining: Int = 1,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask {
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            let image = data.flatMap { data -> UIImage? in
                if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
                    return nil
                }
                return autoreleasepool {
                    self?.makeImage(
                        from: data,
                        maxPixelHeight: targetHeight * UIScreen.main.scale,
                        forceDownsample: forceDownsample
                    )
                }
            }
            if image == nil, let fallbackRequest = fallbackRequests.first, let self = self {
                self.session.configuration.urlCache?.removeCachedResponse(for: request)
                let remainingFallbackRequests = Array(fallbackRequests.dropFirst())
                self.load(
                    request: fallbackRequest,
                    cacheKey: key,
                    targetHeight: targetHeight,
                    forceDownsample: forceDownsample,
                    fallbackRequests: remainingFallbackRequests,
                    retriesRemaining: retriesRemaining,
                    completion: completion
                )
                return
            }
            if image == nil, retriesRemaining > 0, let self = self {
                self.session.configuration.urlCache?.removeCachedResponse(for: request)
                var retryRequest = request
                retryRequest.cachePolicy = .reloadIgnoringLocalCacheData
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                    self.load(
                        request: retryRequest,
                        cacheKey: key,
                        targetHeight: targetHeight,
                        forceDownsample: forceDownsample,
                        fallbackRequests: [],
                        retriesRemaining: retriesRemaining - 1,
                        completion: completion
                    )
                }
                return
            }
            if let image = image {
                self?.store(image, forKey: key)
            } else {
                self?.session.configuration.urlCache?.removeCachedResponse(for: request)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
        task.resume()
        return task
    }

    private func store(_ image: UIImage, forKey key: NSURL) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        let costLimit = aidokuLegacyIsLowMemoryMode() ? CGFloat(1024 * 1024) : CGFloat(16 * 1024 * 1024)
        cache.setObject(image, forKey: key, cost: max(1, Int(min(pixels, costLimit))))
    }

    func makeImage(from data: Data, maxPixelHeight: CGFloat, forceDownsample: Bool = false) -> UIImage? {
        if isAVIF(data) {
            return makeAVIFImage(from: data, maxPixelHeight: maxPixelHeight, forceDownsample: forceDownsample)
        }
        if isWebP(data) {
            return makeWebPImage(from: data, maxPixelHeight: maxPixelHeight, forceDownsample: forceDownsample)
        }

        guard forceDownsample || UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
            return UIImage(data: data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(800, Int(maxPixelHeight))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    func preparedImage(_ image: UIImage, maxPixelHeight: CGFloat) -> UIImage {
        let limit = max(800, maxPixelHeight)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelHeight > limit, pixelWidth > 0 else {
            return image
        }
        let scale = limit / pixelHeight
        let targetSize = CGSize(width: max(1, pixelWidth * scale), height: limit)
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return scaledImage ?? image
    }

    private func makeWebPImage(from data: Data, maxPixelHeight: CGFloat, forceDownsample: Bool) -> UIImage? {
        guard forceDownsample || UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
            return SDImageWebPCoder.shared.decodedImage(with: data, options: nil)
        }
        let maxPixelSize = max(800, Int(maxPixelHeight))
        return SDImageWebPCoder.shared.decodedImage(
            with: data,
            options: [.decodeThumbnailPixelSize: CGSize(width: maxPixelSize, height: maxPixelSize)]
        )
    }

    private func makeAVIFImage(from data: Data, maxPixelHeight: CGFloat, forceDownsample: Bool) -> UIImage? {
        guard forceDownsample || UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
            return AVIFDecoder.decode(data)
        }
        let maxPixelSize = max(800, Int(maxPixelHeight))
        return AVIFDecoder.decode(
            data,
            sampleSize: CGSize(width: maxPixelSize, height: maxPixelSize)
        )
    }

    private func isAVIF(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(32))
        guard
            bytes.count >= 12,
            bytes[4] == 0x66, // f
            bytes[5] == 0x74, // t
            bytes[6] == 0x79, // y
            bytes[7] == 0x70  // p
        else {
            return false
        }
        var index = 8
        while index + 3 < bytes.count {
            if
                bytes[index] == 0x61, // a
                bytes[index + 1] == 0x76, // v
                bytes[index + 2] == 0x69, // i
                (bytes[index + 3] == 0x66 || bytes[index + 3] == 0x73) // f or s
            {
                return true
            }
            index += 4
        }
        return false
    }

    private func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        return bytes[0] == 0x52
            && bytes[1] == 0x49
            && bytes[2] == 0x46
            && bytes[3] == 0x46
            && bytes[8] == 0x57
            && bytes[9] == 0x45
            && bytes[10] == 0x42
            && bytes[11] == 0x50
    }

    static func placeholder(size: CGSize = CGSize(width: 44, height: 62)) -> UIImage {
        let rect = CGRect(origin: .zero, size: size)
        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        LegacyPalette.background.setFill()
        UIRectFill(rect)
        LegacyPalette.accent.withAlphaComponent(0.22).setFill()
        UIBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 5), cornerRadius: 4).fill()
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
}

final class LegacyLibraryViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private let searchController = UISearchController(searchResultsController: nil)
    private let automaticUpdateDefaultsKey = "AidokuLegacy.library.automaticUpdates"
    private let lastAutomaticUpdateDefaultsKey = "AidokuLegacy.library.lastAutomaticUpdate"
    private var entries: [LegacyLibraryEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var libraryObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var isUpdatingLibrary = false
    private var activeCategory: String?
    private var sortOption = LegacyLibrarySortOption.current
    private var pendingCoverRepairs = Set<String>()
    private var coverRepairAttempts: [String: Int] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 94
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search library"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Updates", style: .plain, target: self, action: #selector(openUpdates))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Sort", style: .plain, target: self, action: #selector(showLibraryOptions)),
            UIBarButtonItem(title: "Update", style: .plain, target: self, action: #selector(updateLibraryManually))
        ]

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(updateLibraryManually), for: .valueChanged)
        libraryObserver = NotificationCenter.default.addObserver(
            forName: .legacyLibraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isUpdatingLibrary else { return }
            self.reloadData()
        }
        sourceObserver = NotificationCenter.default.addObserver(
            forName: .legacyInstalledSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateLibraryIfNeeded()
    }

    deinit {
        if let libraryObserver = libraryObserver {
            NotificationCenter.default.removeObserver(libraryObserver)
        }
        if let sourceObserver = sourceObserver {
            NotificationCenter.default.removeObserver(sourceObserver)
        }
    }

    @objc private func reloadData() {
        let query = searchController.searchBar.text
        entries = LegacyLibraryStore.shared.entries(category: activeCategory, query: query, sort: sortOption)
        sources = packageInstaller.loadInstalledSources()
        title = activeCategory.map { $0.isEmpty ? "Uncategorized" : $0 } ?? "Library"
        refreshControl?.endRefreshing()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.isEmpty ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LibraryCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "LibraryCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2

        guard !entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "No manga in Library."
            cell.detailTextLabel?.text = "Open Sources, browse manga, then tap Add."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let entry = entries[indexPath.row]
        loadCover(for: entry, into: cell, at: indexPath)
        cell.textLabel?.text = entry.manga.title
        cell.detailTextLabel?.text = librarySubtitle(for: entry)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !entries.isEmpty else { return }
        let entry = entries[indexPath.row]
        guard let source = source(for: entry) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to open this manga.")
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entry.manga),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        LegacyLibraryStore.shared.remove(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard entries.indices.contains(indexPath.row) else { return nil }
        let entry = entries[indexPath.row]
        let remove = UITableViewRowAction(style: .destructive, title: "Remove") { _, _ in
            LegacyLibraryStore.shared.remove(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
        }
        let category = UITableViewRowAction(style: .normal, title: "Category") { [weak self] _, _ in
            self?.showCategoryPrompt(for: entry)
        }
        return [remove, category]
    }

    private func source(for entry: LegacyLibraryEntry) -> AidokuRunnerLegacySource? {
        return sources.first { $0.key == entry.sourceKey }
    }

    private func librarySubtitle(for entry: LegacyLibraryEntry) -> String {
        var components = [entry.sourceName]
        if let category = entry.category, !category.isEmpty {
            components.append(category)
        }
        let downloadedCount = LegacyDownloadStore.shared.downloadedChapters.filter {
            $0.sourceKey == entry.sourceKey && $0.manga.key == entry.manga.key
        }.count
        if downloadedCount > 0 {
            components.append("\(downloadedCount) downloaded")
        }
        return components.joined(separator: " - ")
    }

    private func loadCover(for entry: LegacyLibraryEntry, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let source = source(for: entry) else { return }
        let coverURLs = entry.manga.coverURLCandidates(relativeTo: source.urls.first)
        guard !coverURLs.isEmpty else {
            repairCover(for: entry, source: source)
            return
        }
        let entryKey = entry.key
        LegacyImageLoader.shared.loadCover(
            urls: coverURLs,
            source: source,
            targetHeight: 130
        ) { [weak self, weak cell] image in
            guard
                let self = self,
                let cell = cell,
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath,
                self.entries.indices.contains(indexPath.row),
                self.entries[indexPath.row].key == entryKey
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
            if image == nil {
                LegacyImageLoader.shared.removeCachedImages(for: coverURLs, source: source)
                self.repairCover(for: entry, source: source)
            } else {
                self.coverRepairAttempts[entryKey] = nil
            }
        }
    }

    private func repairCover(for entry: LegacyLibraryEntry, source: AidokuRunnerLegacySource) {
        let attempts = coverRepairAttempts[entry.key] ?? 0
        guard attempts < 4 else { return }
        guard !pendingCoverRepairs.contains(entry.key) else { return }
        coverRepairAttempts[entry.key] = attempts + 1
        pendingCoverRepairs.insert(entry.key)
        let oldCoverURL = entry.manga.coverURL(relativeTo: source.urls.first)
        source.runner.getMangaUpdate(manga: entry.manga, needsDetails: true, needsChapters: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingCoverRepairs.remove(entry.key)
                guard case .success(let updatedManga) = result else { return }
                let mergedManga = entry.manga.mergedWithUpdate(updatedManga)
                guard !mergedManga.coverURLCandidates(relativeTo: source.urls.first).isEmpty else { return }
                if let oldCoverURL = oldCoverURL {
                    LegacyImageLoader.shared.removeCachedImage(for: oldCoverURL, source: source)
                }
                LegacyImageLoader.shared.removeCachedImages(for: mergedManga.coverURLCandidates(relativeTo: source.urls.first), source: source)
                LegacyLibraryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                self.reloadVisibleLibraryEntry(with: entry.key)
            }
        }
    }

    private func reloadVisibleLibraryEntry(with key: String) {
        guard let row = entries.firstIndex(where: { $0.key == key }) else { return }
        guard let refreshedEntry = LegacyLibraryStore.shared.entry(sourceKey: entries[row].sourceKey, mangaKey: entries[row].manga.key) else {
            reloadData()
            return
        }
        entries[row] = refreshedEntry
        let indexPath = IndexPath(row: row, section: 0)
        guard tableView.indexPathsForVisibleRows?.contains(indexPath) == true else { return }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    @objc private func openUpdates() {
        navigationController?.pushViewController(LegacyUpdatesViewController(), animated: true)
    }

    @objc private func showLibraryOptions() {
        let alert = UIAlertController(title: "Library", message: nil, preferredStyle: .actionSheet)
        for option in LegacyLibrarySortOption.allCases {
            let title = option == sortOption ? "Sort: \(option.title) (Current)" : "Sort: \(option.title)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.sortOption = option
                LegacyLibrarySortOption.setCurrent(option)
                self?.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: activeCategory == nil ? "All Categories (Current)" : "All Categories", style: .default) { [weak self] _ in
            self?.activeCategory = nil
            self?.reloadData()
        })
        alert.addAction(UIAlertAction(title: activeCategory == "" ? "Uncategorized (Current)" : "Uncategorized", style: .default) { [weak self] _ in
            self?.activeCategory = ""
            self?.reloadData()
        })
        for category in LegacyLibraryStore.shared.categories() {
            let title = activeCategory == category ? "\(category) (Current)" : category
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.activeCategory = category
                self?.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alert, animated: true)
    }

    private func showCategoryPrompt(for entry: LegacyLibraryEntry) {
        let alert = UIAlertController(title: "Set Category", message: entry.manga.title, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Category name"
            textField.text = entry.category
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyLibraryStore.shared.setCategory(sourceKey: entry.sourceKey, mangaKey: entry.manga.key, category: nil)
        })
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            LegacyLibraryStore.shared.setCategory(
                sourceKey: entry.sourceKey,
                mangaKey: entry.manga.key,
                category: alert?.textFields?.first?.text
            )
        })
        present(alert, animated: true)
    }

    @objc private func updateLibraryManually() {
        startLibraryUpdate(automatic: false)
    }

    private func updateLibraryIfNeeded() {
        guard UserDefaults.standard.bool(forKey: automaticUpdateDefaultsKey), !isUpdatingLibrary else { return }
        guard !LegacyLibraryStore.shared.rawEntries.isEmpty else { return }
        let now = Date()
        if
            let lastUpdate = UserDefaults.standard.object(forKey: lastAutomaticUpdateDefaultsKey) as? Date,
            now.timeIntervalSince(lastUpdate) < 15 * 60
        {
            return
        }
        UserDefaults.standard.set(now, forKey: lastAutomaticUpdateDefaultsKey)
        startLibraryUpdate(automatic: true)
    }

    private func startLibraryUpdate(automatic: Bool) {
        guard !isUpdatingLibrary else { return }
        let allEntries = LegacyLibraryStore.shared.rawEntries
        let updateItems = allEntries.compactMap { entry -> (LegacyLibraryEntry, AidokuRunnerLegacySource)? in
            guard let source = sources.first(where: { $0.key == entry.sourceKey }) else { return nil }
            return (entry, source)
        }
        let items = automatic && aidokuLegacyIsLowMemoryMode() ? Array(updateItems.prefix(25)) : updateItems
        guard !items.isEmpty else {
            refreshControl?.endRefreshing()
            return
        }
        isUpdatingLibrary = true
        navigationItem.prompt = automatic ? "Updating library..." : "Updating \(items.count) manga..."
        updateLibraryItems(items, index: 0, automatic: automatic)
    }

    private func updateLibraryItems(_ items: [(LegacyLibraryEntry, AidokuRunnerLegacySource)], index: Int, automatic: Bool) {
        guard index < items.count else {
            isUpdatingLibrary = false
            navigationItem.prompt = nil
            refreshControl?.endRefreshing()
            reloadData()
            if !automatic {
                showAlert(title: "Library Updated", message: "Finished checking \(items.count) manga.")
            }
            return
        }
        navigationItem.prompt = "Updating \(index + 1) of \(items.count)..."
        let item = items[index]
        item.1.runner.getMangaUpdate(manga: item.0.manga, needsDetails: true, needsChapters: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .success(let manga) = result {
                    let mergedManga = item.0.manga.mergedWithUpdate(manga)
                    self.recordUpdates(oldManga: item.0.manga, newManga: mergedManga, source: item.1)
                    LegacyLibraryStore.shared.update(manga: mergedManga, source: item.1)
                    LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: item.1)
                    LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: item.1)
                }
                self.updateLibraryItems(items, index: index + 1, automatic: automatic)
            }
        }
    }

    private func recordUpdates(
        oldManga: AidokuRunnerLegacyManga,
        newManga: AidokuRunnerLegacyManga,
        source: AidokuRunnerLegacySource
    ) {
        guard
            let oldChapters = oldManga.chapters,
            !oldChapters.isEmpty,
            let newChapters = newManga.chapters
        else {
            return
        }
        let oldKeys = Set(oldChapters.map { $0.key })
        let addedChapters = newChapters.filter { !oldKeys.contains($0.key) && !$0.locked }
        LegacyUpdateStore.shared.add(source: source, manga: newManga, chapters: addedChapters)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension LegacyLibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        reloadData()
    }
}

final class LegacyHistoryViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var entries: [LegacyHistoryEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?
    private var pendingCoverRepairs = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "History"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadData), for: .valueChanged)
        observer = NotificationCenter.default.addObserver(
            forName: .legacyHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadData() {
        entries = LegacyHistoryStore.shared.entries
        sources = packageInstaller.loadInstalledSources()
        refreshControl?.endRefreshing()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.isEmpty ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HistoryCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "HistoryCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2

        guard !entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "No reading history."
            cell.detailTextLabel?.text = "Open a chapter to start tracking progress."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let entry = entries[indexPath.row]
        loadCover(for: entry, into: cell, at: indexPath)
        cell.textLabel?.text = entry.manga.title
        cell.detailTextLabel?.text = historySubtitle(for: entry)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !entries.isEmpty else { return }
        let entry = entries[indexPath.row]
        guard let source = source(for: entry) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to resume this chapter.")
            return
        }
        navigationController?.pushViewController(
            LegacyReaderFactory.makeReader(
                source: source,
                manga: entry.manga,
                chapter: entry.chapter,
                initialPageIndex: entry.pageIndex
            ),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        LegacyHistoryStore.shared.remove(key: entries[indexPath.row].key)
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard entries.indices.contains(indexPath.row) else { return nil }
        let entry = entries[indexPath.row]
        let removeEntry = UITableViewRowAction(style: .destructive, title: "Remove Entry") { _, _ in
            LegacyHistoryStore.shared.remove(key: entry.key)
        }
        let removeManga = UITableViewRowAction(style: .destructive, title: "Remove Manga") { _, _ in
            LegacyHistoryStore.shared.removeManga(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
        }
        return [removeEntry, removeManga]
    }

    private func source(for entry: LegacyHistoryEntry) -> AidokuRunnerLegacySource? {
        return sources.first { $0.key == entry.sourceKey }
    }

    private func historySubtitle(for entry: LegacyHistoryEntry) -> String {
        let chapterTitle = entry.chapter.legacyFormattedTitle
        if entry.pageCount > 0 {
            return "\(chapterTitle) - Page \(entry.pageIndex + 1) of \(entry.pageCount)\n\(entry.sourceName)"
        }
        return "\(chapterTitle)\n\(entry.sourceName)"
    }

    private func loadCover(for entry: LegacyHistoryEntry, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let source = source(for: entry) else { return }
        let coverURLs = entry.manga.coverURLCandidates(relativeTo: source.urls.first)
        guard !coverURLs.isEmpty else {
            repairCover(for: entry, source: source)
            return
        }
        LegacyImageLoader.shared.loadCover(
            urls: coverURLs,
            source: source,
            targetHeight: 130
        ) { [weak self] image in
            guard
                let self = self,
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
            if image == nil {
                self.repairCover(for: entry, source: source)
            }
        }
    }

    private func repairCover(for entry: LegacyHistoryEntry, source: AidokuRunnerLegacySource) {
        guard !pendingCoverRepairs.contains(entry.key) else { return }
        pendingCoverRepairs.insert(entry.key)
        source.runner.getMangaUpdate(manga: entry.manga, needsDetails: true, needsChapters: false) { [weak self] result in
            DispatchQueue.main.async {
                self?.pendingCoverRepairs.remove(entry.key)
                guard case .success(let updatedManga) = result else { return }
                let mergedManga = entry.manga.mergedWithUpdate(updatedManga)
                guard mergedManga.coverURL(relativeTo: source.urls.first) != nil else { return }
                LegacyLibraryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyUpdatesViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var entries: [LegacyUpdateEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?
    private var pendingCoverRepairs = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Updates"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = 86
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(confirmClear))
        observer = NotificationCenter.default.addObserver(
            forName: .legacyUpdatesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadData() {
        entries = LegacyUpdateStore.shared.entries
        sources = packageInstaller.loadInstalledSources()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.isEmpty ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UpdateCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "UpdateCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        guard !entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "No new chapters recorded."
            cell.detailTextLabel?.text = "Use Library Update to check saved manga."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        let entry = entries[indexPath.row]
        loadCover(for: entry, into: cell, at: indexPath)
        cell.textLabel?.text = entry.manga.title
        let dateText = DateFormatter.localizedString(from: entry.dateFound, dateStyle: .short, timeStyle: .short)
        cell.detailTextLabel?.text = "\(entry.chapter.legacyFormattedTitle)\n\(entry.sourceName) - \(dateText)"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to open this manga.")
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entry.manga),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        LegacyUpdateStore.shared.remove(key: entries[indexPath.row].key)
    }

    private func loadCover(for entry: LegacyUpdateEntry, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else { return }
        let coverURLs = entry.manga.coverURLCandidates(relativeTo: source.urls.first)
        guard !coverURLs.isEmpty else {
            repairCover(for: entry, source: source)
            return
        }
        LegacyImageLoader.shared.loadCover(
            urls: coverURLs,
            source: source,
            targetHeight: 130
        ) { [weak self] image in
            guard
                let self = self,
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
            if image == nil {
                self.repairCover(for: entry, source: source)
            }
        }
    }

    private func repairCover(for entry: LegacyUpdateEntry, source: AidokuRunnerLegacySource) {
        guard !pendingCoverRepairs.contains(entry.key) else { return }
        pendingCoverRepairs.insert(entry.key)
        source.runner.getMangaUpdate(manga: entry.manga, needsDetails: true, needsChapters: false) { [weak self] result in
            DispatchQueue.main.async {
                self?.pendingCoverRepairs.remove(entry.key)
                guard case .success(let updatedManga) = result else { return }
                let mergedManga = entry.manga.mergedWithUpdate(updatedManga)
                guard mergedManga.coverURL(relativeTo: source.urls.first) != nil else { return }
                LegacyLibraryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
            }
        }
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(title: "Clear Updates", message: "Remove recorded chapter updates?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyUpdateStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyDownloadsViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var entries: [LegacyDownloadedChapter] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = 86
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(confirmClear))
        observer = NotificationCenter.default.addObserver(
            forName: .legacyDownloadsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadData() {
        entries = LegacyDownloadStore.shared.downloadedChapters
        sources = packageInstaller.loadInstalledSources()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.isEmpty ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "DownloadCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        guard !entries.isEmpty else {
            cell.textLabel?.text = "No downloaded chapters."
            cell.detailTextLabel?.text = "Open a manga and download chapters for offline reading."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        let entry = entries[indexPath.row]
        cell.textLabel?.text = entry.manga.title
        let size = ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
        cell.detailTextLabel?.text = "\(entry.chapter.legacyFormattedTitle)\n\(entry.sourceName) - \(entry.pageCount) pages - \(size)"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to read this download.")
            return
        }
        navigationController?.pushViewController(
            LegacyReaderFactory.makeReader(source: source, manga: entry.manga, chapter: entry.chapter),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        LegacyDownloadStore.shared.delete(entries[indexPath.row])
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(title: "Clear Downloads", message: "Remove all downloaded chapters?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyDownloadStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacySettingsViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Row: Int, CaseIterable {
        case readerMode
        case readerMemory
        case readerUpscale
        case readerPageNumber
        case readerTapZones
        case darkTheme
        case automaticLibraryUpdates
        case automaticSourceUpdates
        case downloads
        case createBackup
        case restoreBackup
        case clearImageCache
        case clearHistory
        case clearLibrary
        case about
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.row) ?? .about
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SettingsCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryType = row == .about ? .none : .disclosureIndicator
        cell.selectionStyle = row == .about ? .none : .default

        switch row {
            case .readerMode:
                let mode = LegacyReaderMode.current
                cell.textLabel?.text = "Reader Layout"
                cell.detailTextLabel?.text = "\(mode.title) - \(mode.detail)"
            case .readerMemory:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages")
                cell.textLabel?.text = "Reader Memory Mode"
                cell.detailTextLabel?.text = enabled ? "Optimized for iPad Air Gen 1" : "Full-size image decoding"
                cell.accessoryType = enabled ? .checkmark : .none
            case .readerUpscale:
                let enabled = aidokuLegacyReaderUpscaleImages()
                let detail: String
                if enabled {
                    detail = "Sharpen low-resolution pages. Uses more CPU and memory."
                } else {
                    detail = "Use fastest low-memory page decoding."
                }
                cell.textLabel?.text = "Reader Upscale"
                cell.detailTextLabel?.text = detail
                cell.accessoryType = enabled ? .checkmark : .none
            case .readerPageNumber:
                let enabled = aidokuLegacyReaderShowsPageNumber()
                cell.textLabel?.text = "Reader Page Number"
                cell.detailTextLabel?.text = enabled ? "Show page count in the reader." : "Hide page count in the reader."
                cell.accessoryType = enabled ? .checkmark : .none
            case .readerTapZones:
                let enabled = aidokuLegacyReaderShowsTapZones()
                cell.textLabel?.text = "Tap Zones Overlay"
                cell.detailTextLabel?.text = enabled ? "Briefly show previous and next tap zones." : "Do not show tap zone hints."
                cell.accessoryType = enabled ? .checkmark : .none
            case .darkTheme:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.appearance.darkTheme")
                cell.textLabel?.text = "Dark Theme"
                cell.detailTextLabel?.text = enabled ? "Use dark lists and navigation bars" : "Use the light legacy theme"
                cell.accessoryType = enabled ? .checkmark : .none
            case .automaticLibraryUpdates:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.library.automaticUpdates")
                cell.textLabel?.text = "Automatic Library Updates"
                cell.detailTextLabel?.text = enabled ? "Fetch manga details and chapters when Library opens" : "Update saved manga manually"
                cell.accessoryType = enabled ? .checkmark : .none
            case .automaticSourceUpdates:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.sources.automaticUpdates")
                cell.textLabel?.text = "Automatic Source Updates"
                cell.detailTextLabel?.text = enabled ? "Install source package updates when the app opens" : "Update installed sources manually"
                cell.accessoryType = enabled ? .checkmark : .none
            case .downloads:
                let count = LegacyDownloadStore.shared.downloadedChapters.count
                cell.textLabel?.text = "Downloads"
                cell.detailTextLabel?.text = count == 1 ? "1 downloaded chapter" : "\(count) downloaded chapters"
            case .createBackup:
                cell.textLabel?.text = "Create Backup"
                cell.detailTextLabel?.text = "Export library, history, updates, repos, and legacy settings."
            case .restoreBackup:
                cell.textLabel?.text = "Restore Backup"
                cell.detailTextLabel?.text = "Import a legacy JSON backup file."
            case .clearImageCache:
                cell.textLabel?.text = "Clear Image Cache"
                cell.detailTextLabel?.text = "Remove cached covers and reader pages."
            case .clearHistory:
                cell.textLabel?.text = "Clear History"
                cell.detailTextLabel?.text = "Remove local reading progress."
            case .clearLibrary:
                cell.textLabel?.text = "Clear Library"
                cell.detailTextLabel?.text = "Remove saved manga from Aidoku Legacy."
            case .about:
                cell.textLabel?.text = "Aidoku Legacy"
                cell.detailTextLabel?.text = "iOS 12 personal-use reader with AidokuRunnerLegacy."
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = Row(rawValue: indexPath.row) else { return }
        switch row {
            case .readerMode:
                showReaderModePicker(from: indexPath)
            case .readerMemory:
                let key = "AidokuLegacy.reader.downsampleImages"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                aidokuLegacyTrimVolatileCaches()
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .readerUpscale:
                let key = "AidokuLegacy.reader.upscaleImages"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                aidokuLegacyTrimVolatileCaches()
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .readerPageNumber:
                let key = "AidokuLegacy.reader.showPageNumber"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .readerTapZones:
                let key = "AidokuLegacy.reader.showTapZones"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .darkTheme:
                let key = "AidokuLegacy.appearance.darkTheme"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                view.backgroundColor = LegacyPalette.background
                tableView.backgroundColor = LegacyPalette.background
                tableView.reloadData()
                NotificationCenter.default.post(name: .legacyAppearanceDidChange, object: nil)
            case .automaticLibraryUpdates:
                let key = "AidokuLegacy.library.automaticUpdates"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .automaticSourceUpdates:
                let key = "AidokuLegacy.sources.automaticUpdates"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .downloads:
                navigationController?.pushViewController(LegacyDownloadsViewController(), animated: true)
            case .createBackup:
                createBackup()
            case .restoreBackup:
                showRestoreOptions(from: indexPath)
            case .clearImageCache:
                LegacyImageLoader.shared.clear()
            case .clearHistory:
                confirmClearHistory()
            case .clearLibrary:
                confirmClearLibrary()
            case .about:
                break
        }
    }

    private func createBackup() {
        do {
            let url = try LegacyBackupManager.shared.createBackup()
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            present(controller, animated: true)
        } catch {
            showAlert(title: "Backup Failed", message: error.localizedDescription)
        }
    }

    private func showRestoreOptions(from indexPath: IndexPath) {
        let backups = LegacyBackupManager.shared.backupURLs()
        let alert = UIAlertController(title: "Restore Backup", message: nil, preferredStyle: .actionSheet)
        if let latest = backups.first {
            alert.addAction(UIAlertAction(title: "Restore Latest Local Backup", style: .default) { [weak self] _ in
                self?.confirmRestore(url: latest)
            })
        }
        alert.addAction(UIAlertAction(title: "Import Backup File", style: .default) { [weak self] _ in
            self?.openBackupPicker()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func openBackupPicker() {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.data"], in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    private func confirmRestore(url: URL) {
        let alert = UIAlertController(
            title: "Restore Backup",
            message: "This replaces the local legacy library, history, updates, repositories, and settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restore", style: .destructive) { [weak self] _ in
            self?.restoreBackup(url: url)
        })
        present(alert, animated: true)
    }

    private func restoreBackup(url: URL) {
        do {
            try LegacyBackupManager.shared.restore(from: url)
            tableView.reloadData()
            showAlert(title: "Backup Restored", message: "Restart the app if a source setting does not refresh immediately.")
        } catch {
            showAlert(title: "Restore Failed", message: error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        confirmRestore(url: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        dismiss(animated: true)
    }

    private func showReaderModePicker(from indexPath: IndexPath) {
        let currentMode = LegacyReaderMode.current
        let alert = UIAlertController(
            title: "Reader Layout",
            message: "Choose how chapter pages are displayed.",
            preferredStyle: .actionSheet
        )
        for mode in LegacyReaderMode.allCases {
            let title = mode == currentMode ? "\(mode.title) (Current)" : mode.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                LegacyReaderMode.setCurrent(mode)
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: "Clear History",
            message: "Remove all reading history from Aidoku Legacy?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyHistoryStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func confirmClearLibrary() {
        let alert = UIAlertController(
            title: "Clear Library",
            message: "Remove all saved manga from Aidoku Legacy?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyLibraryStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyRootViewController: UITableViewController {
    private let catalogClient = LegacySourceCatalogClient()
    private let repositoryStore = LegacySourceRepositoryStore.shared
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private let searchController = UISearchController(searchResultsController: nil)

    private var catalog: LegacySourceCatalog?
    private var allSources: [LegacySourceInfo] = []
    private var visibleSources: [LegacySourceInfo] = []
    private var installedSources: [AidokuRunnerLegacySource] = []
    private var loadingText = "Loading Aidoku Community Sources..."

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Browse"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search sources"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadCatalog), for: .valueChanged)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Installed",
            style: .plain,
            target: self,
            action: #selector(showInstalledSources)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Repos",
            style: .plain,
            target: self,
            action: #selector(showRepositoryOptions)
        )

        reloadInstalledSources()
        reloadCatalog()
    }

    @objc private func reloadCatalog() {
        loadingText = "Loading Aidoku Community Sources..."
        tableView.reloadData()

        catalogClient.fetchCatalogs(from: repositoryStore.repositoryURLs) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshControl?.endRefreshing()

                switch result {
                    case .success(let catalog):
                        self.catalog = catalog
                        self.allSources = catalog.sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        self.applySearch()
                    case .failure(let error):
                        self.catalog = nil
                        self.allSources = []
                        self.visibleSources = []
                        self.loadingText = error.localizedDescription
                }

                self.tableView.reloadData()
            }
        }
    }

    private func applySearch() {
        let query = searchController.searchBar.text ?? ""
        visibleSources = allSources.filter { $0.matches(query: query) }
    }

    private func reloadInstalledSources() {
        installedSources = packageInstaller.loadInstalledSources()
        navigationItem.rightBarButtonItem?.title = installedSources.isEmpty ? "Installed" : "Installed (\(installedSources.count))"
    }

    @objc private func showInstalledSources() {
        if installedSources.isEmpty {
            showAlert(title: "Installed Sources", message: "No sources installed.")
            return
        }

        let viewController = LegacyInstalledSourcesViewController(sources: installedSources)
        navigationController?.pushViewController(viewController, animated: true)
    }

    @objc private func showRepositoryOptions() {
        let repos = repositoryStore.repositoryURLs.map { $0.absoluteString }.joined(separator: "\n")
        let alert = UIAlertController(title: "Source Repositories", message: repos, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Add Source Repo", style: .default) { [weak self] _ in
            self?.promptForRepository()
        })
        alert.addAction(UIAlertAction(title: "Refresh Repos", style: .default) { [weak self] _ in
            self?.reloadCatalog()
        })
        alert.addAction(UIAlertAction(title: "Reset to Community Repo", style: .destructive) { [weak self] _ in
            self?.repositoryStore.resetToDefault()
            self?.reloadCatalog()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }
        present(alert, animated: true)
    }

    private func promptForRepository() {
        let alert = UIAlertController(
            title: "Add Source Repo",
            message: "Paste an index.min.json URL or a GitHub owner/repo URL.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/sources/index.min.json"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard
                let self = self,
                let value = alert?.textFields?.first?.text,
                let url = self.repositoryStore.normalizedURL(from: value)
            else {
                self?.showAlert(title: "Invalid Repo", message: "Enter a valid source repository URL.")
                return
            }
            self.repositoryStore.add(url)
            self.reloadCatalog()
        })
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visibleSources.isEmpty ? 1 : visibleSources.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if let catalog = catalog {
            return "\(catalog.name) - \(visibleSources.count) sources"
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SourceCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText

        guard !visibleSources.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = loadingText
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let source = visibleSources[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
        if let iconURL = source.resolvedIconURL {
            LegacyImageLoader.shared.load(url: iconURL, targetHeight: 48) { image in
                guard
                    let visibleIndexPath = tableView.indexPath(for: cell),
                    visibleIndexPath == indexPath
                else { return }
                cell.imageView?.image = image ?? LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
                cell.setNeedsLayout()
            }
        }
        cell.textLabel?.text = source.name
        cell.detailTextLabel?.text = source.displaySubtitle
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !visibleSources.isEmpty else { return }
        showDetails(for: visibleSources[indexPath.row])
    }

    private func showDetails(for source: LegacySourceInfo) {
        let details = [
            source.id,
            "Version \(source.version)",
            source.languageText,
            source.ratingText,
            source.baseURL
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        let alert = UIAlertController(title: source.name, message: details, preferredStyle: .actionSheet)
        if let url = source.resolvedBaseURL {
            alert.addAction(UIAlertAction(title: "Browse Website", style: .default) { [weak self] _ in
                self?.openWebsite(url, title: source.name)
            })
        }
        alert.addAction(UIAlertAction(title: "Download Package", style: .default) { [weak self] _ in
            self?.download(source: source)
        })
        if let url = source.resolvedDownloadURL {
            alert.addAction(UIAlertAction(title: "Copy Package URL", style: .default) { _ in
                UIPasteboard.general.string = url.absoluteString
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: visibleSources.firstIndex { $0.id == source.id } ?? 0, section: 0))
        }

        present(alert, animated: true)
    }

    private func download(source: LegacySourceInfo) {
        loadingText = "Downloading \(source.name)..."
        tableView.reloadData()

        catalogClient.downloadPackage(for: source) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                    case .success(let packageURL):
                        self.installPackage(at: packageURL, sourceName: source.name)
                    case .failure(let error):
                        self.showAlert(title: "Download Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func installPackage(at packageURL: URL, sourceName: String) {
        loadingText = "Installing \(sourceName)..."
        tableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async {
            let installResult: Result<AidokuRunnerLegacySource, Error>
            do {
                installResult = .success(try self.packageInstaller.installPackage(at: packageURL))
            } catch {
                installResult = .failure(error)
            }

            DispatchQueue.main.async {
                switch installResult {
                    case .success(let source):
                        self.reloadInstalledSources()
                        LegacyImageLoader.shared.clear()
                        NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
                        self.showInstallSuccess(source)
                    case .failure(let error):
                        self.showAlert(title: "Install Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func showInstallSuccess(_ source: AidokuRunnerLegacySource) {
        let alert = UIAlertController(
            title: "Source Installed",
            message: "\(source.name) is ready in Installed Sources.",
            preferredStyle: .alert
        )
        if let url = source.urls.first {
            alert.addAction(UIAlertAction(title: "Browse Source", style: .default) { [weak self] _ in
                self?.openWebsite(url, title: source.name)
            })
        }
        alert.addAction(UIAlertAction(title: "Open Source", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(LegacySourceMenuViewController(source: source), animated: true)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    fileprivate func openWebsite(_ url: URL, title: String) {
        let viewController = LegacySourceWebViewController(url: url, title: title)
        navigationController?.pushViewController(viewController, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension LegacyRootViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        applySearch()
        tableView.reloadData()
    }
}

final class LegacyInstalledSourcesViewController: UITableViewController {
    private let repositoryStore = LegacySourceRepositoryStore.shared
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var sources: [AidokuRunnerLegacySource]
    private var observer: NSObjectProtocol?

    init(sources: [AidokuRunnerLegacySource]? = nil) {
        self.sources = (sources ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(style: .plain)
        title = "Sources"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
        navigationItem.largeTitleDisplayMode = .automatic
        navigationController?.navigationBar.prefersLargeTitles = true
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadSources), for: .valueChanged)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Repos",
            style: .plain,
            target: self,
            action: #selector(showRepositoryOptions)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Batch Search", style: .plain, target: self, action: #selector(openBatchSearch)),
            UIBarButtonItem(title: "Update", style: .plain, target: self, action: #selector(updateInstalledSources))
        ]
        observer = NotificationCenter.default.addObserver(
            forName: .legacyInstalledSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadSources()
        }
        if sources.isEmpty {
            reloadSources()
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadSources() {
        sources = packageInstaller.loadInstalledSources()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshControl?.endRefreshing()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sources.isEmpty ? 1 : sources.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "InstalledSourceCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "InstalledSourceCell")
        guard !sources.isEmpty else {
            cell.backgroundColor = LegacyPalette.panel
            cell.textLabel?.textColor = LegacyPalette.primaryText
            cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
            cell.imageView?.image = nil
            cell.textLabel?.text = "No sources installed."
            cell.detailTextLabel?.text = "Open Browse to install Aidoku Community sources."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        let source = sources[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.imageView?.image = source.imageUrl.flatMap {
            UIImage(contentsOfFile: $0.path)
        } ?? LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
        cell.textLabel?.text = source.name
        cell.detailTextLabel?.text = "\(source.key)  v\(source.version)  \(source.languages.joined(separator: ", "))"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sources.isEmpty else { return }
        let source = sources[indexPath.row]
        navigationController?.pushViewController(LegacySourceMenuViewController(source: source), animated: true)
    }

    @objc private func openBatchSearch() {
        let loadedSources = sources.isEmpty ? packageInstaller.loadInstalledSources() : sources
        navigationController?.pushViewController(
            LegacyBatchMangaSearchViewController(sources: loadedSources),
            animated: true
        )
    }

    @objc private func updateInstalledSources() {
        guard !(sources.isEmpty ? packageInstaller.loadInstalledSources() : sources).isEmpty else {
            showAlert(title: "No Sources", message: "Install sources before checking for updates.")
            return
        }
        LegacySourceUpdateManager.shared.updateInstalledSources(automatic: false, progress: { [weak self] message in
            self?.navigationItem.prompt = message
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.reloadSources()
            if let error = result.error {
                self.showAlert(title: "Update Failed", message: error.localizedDescription)
            } else if result.skipped {
                self.showAlert(title: "Update Skipped", message: "A source update is already running.")
            } else if result.updatedCount == 0 && result.failedCount == 0 {
                self.showAlert(title: "Sources Current", message: "Installed sources are already up to date.")
            } else {
                let failedText = result.failedCount > 0 ? " \(result.failedCount) failed." : ""
                self.showAlert(
                    title: "Sources Updated",
                    message: "Updated \(result.updatedCount) source package(s).\(failedText)"
                )
            }
        })
    }

    @objc private func showRepositoryOptions() {
        let repos = repositoryStore.repositoryURLs.map { $0.absoluteString }.joined(separator: "\n")
        let alert = UIAlertController(title: "Source Repositories", message: repos, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Add Source Repo", style: .default) { [weak self] _ in
            self?.promptForRepository()
        })
        alert.addAction(UIAlertAction(title: "Check Source Updates", style: .default) { [weak self] _ in
            self?.updateInstalledSources()
        })
        alert.addAction(UIAlertAction(title: "Reset to Community Repo", style: .destructive) { [weak self] _ in
            self?.repositoryStore.resetToDefault()
            self?.updateInstalledSources()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }
        present(alert, animated: true)
    }

    private func promptForRepository() {
        let alert = UIAlertController(
            title: "Add Source Repo",
            message: "Paste an index.min.json URL or a GitHub owner/repo URL.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/sources/index.min.json"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard
                let self = self,
                let value = alert?.textFields?.first?.text,
                let url = self.repositoryStore.normalizedURL(from: value)
            else {
                self?.showAlert(title: "Invalid Repo", message: "Enter a valid source repository URL.")
                return
            }
            self.repositoryStore.add(url)
            if self.sources.isEmpty {
                self.showAlert(title: "Repo Added", message: "Open Browse to install sources from this repository.")
            } else {
                self.updateInstalledSources()
            }
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyBatchMangaSearchViewController: UITableViewController {
    private struct Section {
        let source: AidokuRunnerLegacySource
        var entries: [AidokuRunnerLegacyManga]
        var error: String?
    }

    private let sources: [AidokuRunnerLegacySource]
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounceTimer: Timer?
    private var sections: [Section] = []
    private var isLoading = false
    private var message = "Enter a search term."

    init(sources: [AidokuRunnerLegacySource]) {
        self.sources = sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(style: .plain)
        title = "Batch Search"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        searchController.searchBar.placeholder = "Search all installed sources"
        searchController.searchBar.delegate = self
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        definesPresentationContext = true
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.isEmpty ? 1 : sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !sections.isEmpty else { return 1 }
        let section = sections[section]
        if !section.entries.isEmpty { return section.entries.count }
        return section.error == nil ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !sections.isEmpty else { return nil }
        let section = sections[section]
        let count = section.entries.count
        return count == 0 ? section.source.name : "\(section.source.name) (\(count))"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BatchSearchCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "BatchSearchCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2

        guard !sections.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Searching..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let section = sections[indexPath.section]
        guard !section.entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "Search failed"
            cell.detailTextLabel?.text = section.error
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let manga = section.entries[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: manga.coverURLCandidates(relativeTo: section.source.urls.first),
            source: section.source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
        cell.textLabel?.text = manga.title
        cell.detailTextLabel?.text = manga.authors?.joined(separator: ", ") ?? manga.description ?? section.source.name
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sections.isEmpty, sections[indexPath.section].entries.indices.contains(indexPath.row) else { return }
        let section = sections[indexPath.section]
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: section.source, manga: section.entries[indexPath.row]),
            animated: true
        )
    }

    private func search(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            sections = []
            isLoading = false
            message = trimmedQuery.isEmpty ? "Enter a search term." : "Keep typing..."
            tableView.reloadData()
            return
        }
        guard !sources.isEmpty else {
            sections = []
            isLoading = false
            message = "No sources installed."
            tableView.reloadData()
            return
        }

        isLoading = true
        sections = []
        message = "Searching..."
        tableView.reloadData()

        let currentQuery = trimmedQuery
        let group = DispatchGroup()
        var collected: [Section] = []
        let lock = NSLock()

        for source in sources {
            group.enter()
            source.runner.getSearchMangaList(query: currentQuery, page: 1, filters: []) { result in
                let section: Section?
                switch result {
                    case .success(let page):
                        section = page.entries.isEmpty ? nil : Section(source: source, entries: page.entries, error: nil)
                    case .failure(let error):
                        section = Section(source: source, entries: [], error: error.localizedDescription)
                }
                if let section = section {
                    lock.lock()
                    collected.append(section)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let latestQuery = self.searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard latestQuery == currentQuery else { return }
            self.sections = collected.sorted { lhs, rhs in
                lhs.source.name.localizedCaseInsensitiveCompare(rhs.source.name) == .orderedAscending
            }
            self.isLoading = false
            self.message = self.sections.isEmpty ? "No manga found." : ""
            self.tableView.reloadData()
        }
    }
}

extension LegacyBatchMangaSearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        search(query: searchBar.text ?? "")
    }
}

extension LegacyBatchMangaSearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchDebounceTimer?.invalidate()
        let query = searchController.searchBar.text ?? ""
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            sections = []
            isLoading = false
            message = trimmedQuery.isEmpty ? "Enter a search term." : "Keep typing..."
            tableView.reloadData()
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            self?.search(query: query)
        }
    }
}

final class LegacySourceMenuViewController: UITableViewController {
    private enum Row {
        case home
        case search
        case settings
        case listing(AidokuRunnerLegacyListing)
        case website(URL)
        case message(title: String, subtitle: String?)
    }

    private let source: AidokuRunnerLegacySource
    private var rows: [Row] = []

    init(source: AidokuRunnerLegacySource) {
        self.source = source
        super.init(style: .grouped)
        title = source.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        rows = []
        if source.runner.features.providesHome {
            rows.append(.home)
        }
        rows.append(.search)
        if source.hasConfigurableSettings {
            rows.append(.settings)
        }
        rows.append(contentsOf: source.staticListings.map { .listing($0) })
        if source.runner.features.dynamicListings {
            rows.append(.message(title: "Loading Listings...", subtitle: nil))
            loadDynamicListings()
        }
        if let url = source.urls.first {
            rows.append(.website(url))
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceMenuCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SourceMenuCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch rows[indexPath.row] {
            case .home:
                cell.textLabel?.text = "Home"
                cell.detailTextLabel?.text = "Run get_home"
            case .search:
                cell.textLabel?.text = "Search Manga"
                cell.detailTextLabel?.text = "Run get_search_manga_list"
            case .settings:
                cell.textLabel?.text = "Source Settings"
                cell.detailTextLabel?.text = "Languages, content ratings, and source options"
            case .listing(let listing):
                cell.textLabel?.text = listing.name
                cell.detailTextLabel?.text = "Run get_manga_list"
            case .website(let url):
                cell.textLabel?.text = "Browse Website"
                cell.detailTextLabel?.text = url.absoluteString
            case .message(let title, let subtitle):
                cell.textLabel?.text = title
                cell.detailTextLabel?.text = subtitle
                cell.accessoryType = .none
                cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
            case .home:
                navigationController?.pushViewController(LegacySourceHomeViewController(source: source), animated: true)
            case .search:
                navigationController?.pushViewController(LegacyMangaListViewController(source: source, listing: nil), animated: true)
            case .settings:
                navigationController?.pushViewController(LegacySourceSettingsViewController(source: source), animated: true)
            case .listing(let listing):
                navigationController?.pushViewController(LegacyMangaListViewController(source: source, listing: listing), animated: true)
            case .website(let url):
                navigationController?.pushViewController(LegacySourceWebViewController(url: url, title: source.name), animated: true)
            case .message:
                return
        }
    }

    private func loadDynamicListings() {
        source.runner.getListings { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rows.removeAll {
                    if case .message(let title, _) = $0 {
                        return title == "Loading Listings..." || title == "Listings Unavailable"
                    }
                    return false
                }
                switch result {
                    case .success(let listings):
                        let existing = Set(self.source.staticListings.map { $0.id })
                        let dynamicRows = listings
                            .filter { !existing.contains($0.id) }
                            .map { Row.listing($0) }
                        let prefixCount = self.fixedPrefixCount
                        let insertIndex = min(prefixCount + self.source.staticListings.count, self.rows.count)
                        self.rows.insert(contentsOf: dynamicRows, at: insertIndex)
                    case .failure(let error):
                        let prefixCount = self.fixedPrefixCount
                        self.rows.insert(
                            .message(title: "Listings Unavailable", subtitle: error.localizedDescription),
                            at: min(prefixCount + self.source.staticListings.count, self.rows.count)
                        )
                }
                self.tableView.reloadData()
            }
        }
    }

    private var fixedPrefixCount: Int {
        var count = 1 // Search
        if source.runner.features.providesHome {
            count += 1
        }
        if source.hasConfigurableSettings {
            count += 1
        }
        return count
    }
}

final class LegacySourceSettingsViewController: UITableViewController {
    private enum LoginKeys {
        static let loggedInValue = "logged_in"
        static let usernameSuffix = ".username"
        static let passwordSuffix = ".password"
        static let cookieKeysSuffix = ".keys"
        static let cookieValuesSuffix = ".values"
        static let localStoragePrefix = ".ls."
    }

    private enum Row {
        case languages
        case baseURL
        case setting(AidokuRunnerLegacySettingItem)
    }

    private struct Section {
        let title: String?
        let rows: [Row]
    }

    private let source: AidokuRunnerLegacySource
    private var sections: [Section] = []
    private var settings: [AidokuRunnerLegacySettingItem] = []

    init(source: AidokuRunnerLegacySource) {
        self.source = source
        self.settings = source.staticSettings
        super.init(style: .grouped)
        title = "Source Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        buildSections()
        loadSettings()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceSettingCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SourceSettingCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator

        switch sections[indexPath.section].rows[indexPath.row] {
            case .languages:
                cell.textLabel?.text = "Languages"
                cell.detailTextLabel?.text = selectedLanguages().joined(separator: ", ")
            case .baseURL:
                cell.textLabel?.text = "Base URL"
                cell.detailTextLabel?.text = currentBaseURL()
            case .setting(let setting):
                cell.textLabel?.text = settingTitle(setting)
                cell.detailTextLabel?.text = detailText(for: setting)
                if setting.type == "switch" || setting.type == "toggle" {
                    cell.accessoryType = boolValue(for: setting) ? .checkmark : .none
                }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
            case .languages:
                openLanguagePicker()
            case .baseURL:
                openBaseURLPicker()
            case .setting(let setting):
                edit(setting)
        }
    }

    private func buildSections() {
        sections.removeAll()
        var sourceRows: [Row] = []
        if source.languages.count > 1 {
            sourceRows.append(.languages)
        }
        if (source.config?.allowsBaseUrlSelect ?? false) && source.urls.count > 1 {
            sourceRows.append(.baseURL)
        }
        if !sourceRows.isEmpty {
            sections.append(Section(title: "Source", rows: sourceRows))
        }

        var looseRows: [Row] = []
        for setting in settings {
            if setting.type == "group" || setting.type == "page" {
                let rows = settingRows(in: setting.items ?? [])
                if !rows.isEmpty {
                    sections.append(Section(title: setting.title, rows: rows))
                }
            } else if isEditable(setting) {
                looseRows.append(.setting(setting))
            }
        }
        if !looseRows.isEmpty {
            sections.append(Section(title: "Settings", rows: looseRows))
        }
    }

    private func loadSettings() {
        guard source.runner.features.dynamicSettings else { return }
        source.getSettings { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                    case .success(let settings):
                        self.settings = settings
                        self.buildSections()
                        self.tableView.reloadData()
                    case .failure(let error):
                        self.showMessage(title: "Settings Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func settingRows(in settings: [AidokuRunnerLegacySettingItem]) -> [Row] {
        var rows: [Row] = []
        for setting in settings {
            if setting.type == "group" || setting.type == "page" {
                rows.append(contentsOf: settingRows(in: setting.items ?? []))
            } else if isEditable(setting) {
                rows.append(.setting(setting))
            }
        }
        return rows
    }

    private func isEditable(_ setting: AidokuRunnerLegacySettingItem) -> Bool {
        if setting.type == "link" {
            return resolvedURL(for: setting) != nil
        }
        if setting.type == "button" {
            return setting.notification != nil || setting.action != nil
        }
        guard setting.key != nil else { return false }
        switch setting.type {
            case "select", "segment", "multi-select", "multi-single-select", "switch", "toggle", "text", "stepper", "editable-list", "login":
                return true
            default:
                return false
        }
    }

    private func openLanguagePicker() {
        let allowsMultiple = (source.config?.languageSelectType ?? .multiple) != .single
        let selected = Set(selectedLanguages())
        let options = source.languages.map { language -> (label: String, value: String) in
            let label = Locale.current.localizedString(forIdentifier: language) ?? language
            return (label, language)
        }
        let picker = LegacyFilterOptionPickerViewController(
            title: "Languages",
            options: options,
            selectedValues: selected,
            allowsMultiple: allowsMultiple,
            allowsExclusion: false
        ) { [weak self] selected, _ in
            guard let self = self else { return }
            if allowsMultiple {
                UserDefaults.standard.set(Array(selected).sorted(), forKey: "\(self.source.key).languages")
            } else if let first = selected.first {
                UserDefaults.standard.set(first, forKey: "\(self.source.key).language")
                UserDefaults.standard.set([first], forKey: "\(self.source.key).languages")
            }
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func openBaseURLPicker() {
        let options = source.urls.map { ($0.absoluteString, $0.absoluteString) }
        let picker = LegacyFilterOptionPickerViewController(
            title: "Base URL",
            options: options,
            selectedValues: Set([currentBaseURL()]),
            allowsMultiple: false,
            allowsExclusion: false
        ) { [weak self] selected, _ in
            guard let self = self, let value = selected.first else { return }
            UserDefaults.standard.set(value, forKey: "\(self.source.key).url")
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func edit(_ setting: AidokuRunnerLegacySettingItem) {
        switch setting.type {
            case "link":
                openLink(setting)
            case "button":
                notifySettingChanged(setting)
            case "switch", "toggle":
                guard let key = setting.key else { return }
                let defaultsKey = "\(source.key).\(key)"
                UserDefaults.standard.set(!boolValue(for: setting), forKey: defaultsKey)
                notifySettingChanged(setting)
                tableView.reloadData()
            case "select", "segment":
                openSettingPicker(setting: setting, allowsMultiple: false)
            case "multi-select", "multi-single-select":
                openSettingPicker(setting: setting, allowsMultiple: true)
            case "text", "stepper":
                editText(setting: setting)
            case "editable-list":
                editList(setting: setting)
            case "login":
                editLogin(setting)
            default:
                return
        }
    }

    private func openSettingPicker(setting: AidokuRunnerLegacySettingItem, allowsMultiple: Bool) {
        guard let key = setting.key, setting.values?.isEmpty == false else { return }
        let defaultsKey = "\(source.key).\(key)"
        let selected: Set<String> = allowsMultiple
            ? Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            : Set([UserDefaults.standard.string(forKey: defaultsKey) ?? ""])
        let picker = LegacyFilterOptionPickerViewController(
            title: settingTitle(setting),
            options: options(for: setting),
            selectedValues: selected,
            allowsMultiple: allowsMultiple,
            allowsExclusion: false
        ) { [weak self] selected, _ in
            guard let self = self else { return }
            if allowsMultiple {
                UserDefaults.standard.set(Array(selected).sorted(), forKey: defaultsKey)
            } else if let value = selected.first {
                UserDefaults.standard.set(value, forKey: defaultsKey)
            }
            self.notifySettingChanged(setting)
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func editText(setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        let alert = UIAlertController(title: settingTitle(setting), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = self.stringValue(forKey: defaultsKey)
            if setting.type == "stepper" {
                textField.keyboardType = .decimalPad
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text else { return }
            if setting.type == "stepper", let number = Double(text) {
                UserDefaults.standard.set(number, forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(text, forKey: defaultsKey)
            }
            self.notifySettingChanged(setting)
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func editList(setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        let alert = UIAlertController(
            title: settingTitle(setting),
            message: "Enter comma-separated values.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).joined(separator: ", ")
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text else { return }
            let values = text
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            UserDefaults.standard.set(values, forKey: defaultsKey)
            self.notifySettingChanged(setting)
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func editLogin(_ setting: AidokuRunnerLegacySettingItem) {
        guard setting.key != nil else { return }
        if isLoggedIn(setting) {
            confirmLogout(setting)
            return
        }

        switch setting.method?.lowercased() {
            case "web", "oauth":
                openWebLogin(setting)
            default:
                openBasicLogin(setting)
        }
    }

    private func openBasicLogin(_ setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        let alert = UIAlertController(
            title: settingTitle(setting),
            message: setting.subtitle ?? "Enter your source account credentials.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = UserDefaults.standard.string(forKey: defaultsKey + LoginKeys.usernameSuffix)
            textField.placeholder = (setting.useEmail ?? false) ? "Email" : "Username"
            textField.keyboardType = (setting.useEmail ?? false) ? .emailAddress : .default
            textField.textContentType = (setting.useEmail ?? false) ? .emailAddress : .username
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addTextField { textField in
            textField.text = UserDefaults.standard.string(forKey: defaultsKey + LoginKeys.passwordSuffix)
            textField.placeholder = "Password"
            textField.textContentType = .password
            textField.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak self, weak alert] _ in
            guard
                let self = self,
                let textFields = alert?.textFields,
                textFields.count >= 2,
                let username = textFields[0].text,
                let password = textFields[1].text,
                !username.isEmpty,
                !password.isEmpty
            else { return }
            self.finishBasicLogin(setting: setting, username: username, password: password)
        })
        present(alert, animated: true)
    }

    private func finishBasicLogin(setting: AidokuRunnerLegacySettingItem, username: String, password: String) {
        guard let key = setting.key else { return }
        source.runner.handleBasicLogin(key: key, username: username, password: password) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(true):
                    let defaultsKey = "\(self.source.key).\(key)"
                    UserDefaults.standard.set(username, forKey: defaultsKey + LoginKeys.usernameSuffix)
                    UserDefaults.standard.set(password, forKey: defaultsKey + LoginKeys.passwordSuffix)
                    UserDefaults.standard.set(LoginKeys.loggedInValue, forKey: defaultsKey)
                    self.notifySettingChanged(setting)
                    self.tableView.reloadData()
                case .success(false):
                    self.showMessage(title: "Login Failed", message: "The source rejected the credentials.")
                case .failure(let error):
                    self.showMessage(title: "Login Failed", message: error.localizedDescription)
            }
        }
    }

    private func openWebLogin(_ setting: AidokuRunnerLegacySettingItem) {
        guard let url = resolvedURL(for: setting) else {
            showMessage(title: "Login Failed", message: "This source did not provide a login URL.")
            return
        }
        let controller = LegacySourceWebViewController(
            url: url,
            title: settingTitle(setting),
            localStorageKeys: setting.localStorageKeys ?? []
        ) { [weak self] result in
            self?.finishWebLogin(setting: setting, result: result)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func finishWebLogin(setting: AidokuRunnerLegacySettingItem, result: LegacyWebLoginResult) {
        guard let key = setting.key else { return }
        guard !result.cookies.isEmpty || !result.localStorage.isEmpty else {
            showMessage(title: "Login Failed", message: "No login cookies or local storage values were found.")
            return
        }
        source.runner.handleWebLogin(key: key, cookies: result.cookies) { [weak self] loginResult in
            guard let self = self else { return }
            switch loginResult {
                case .success(true):
                    let defaultsKey = "\(self.source.key).\(key)"
                    let cookieKeys = result.cookies.keys.sorted()
                    let cookieValues = cookieKeys.map { result.cookies[$0] ?? "" }
                    UserDefaults.standard.set(cookieKeys, forKey: defaultsKey + LoginKeys.cookieKeysSuffix)
                    UserDefaults.standard.set(cookieValues, forKey: defaultsKey + LoginKeys.cookieValuesSuffix)
                    for (storageKey, storageValue) in result.localStorage {
                        UserDefaults.standard.set(storageValue, forKey: defaultsKey + LoginKeys.localStoragePrefix + storageKey)
                    }
                    UserDefaults.standard.set(LoginKeys.loggedInValue, forKey: defaultsKey)
                    self.notifySettingChanged(setting)
                    self.tableView.reloadData()
                    self.navigationController?.popViewController(animated: true)
                case .success(false):
                    self.showMessage(title: "Login Failed", message: "The source did not accept the web login.")
                case .failure(let error):
                    self.showMessage(title: "Login Failed", message: error.localizedDescription)
            }
        }
    }

    private func confirmLogout(_ setting: AidokuRunnerLegacySettingItem) {
        let alert = UIAlertController(
            title: setting.logoutTitle ?? "Log Out",
            message: "Remove saved login data for this source?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.logout(setting)
        })
        present(alert, animated: true)
    }

    private func logout(_ setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.usernameSuffix)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.passwordSuffix)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.cookieKeysSuffix)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.cookieValuesSuffix)
        for localStorageKey in setting.localStorageKeys ?? [] {
            UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.localStoragePrefix + localStorageKey)
        }
        notifySettingChanged(setting)
        tableView.reloadData()
    }

    private func openLink(_ setting: AidokuRunnerLegacySettingItem) {
        guard let url = resolvedURL(for: setting) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func notifySettingChanged(_ setting: AidokuRunnerLegacySettingItem) {
        if let action = setting.action {
            NotificationCenter.default.post(name: Notification.Name(action), object: nil)
        }
        if let notification = setting.notification {
            source.runner.handleNotification(notification: notification) { result in
                if case .failure(let error) = result {
                    print("[AidokuLegacy] setting notification failed: \(error)")
                }
            }
            NotificationCenter.default.post(name: Notification.Name(notification), object: nil)
        }
        for refresh in setting.refreshes ?? [] {
            NotificationCenter.default.post(name: Notification.Name("refresh-\(refresh)"), object: nil)
        }
    }

    private func isLoggedIn(_ setting: AidokuRunnerLegacySettingItem) -> Bool {
        guard let key = setting.key else { return false }
        return !(UserDefaults.standard.string(forKey: "\(source.key).\(key)") ?? "").isEmpty
    }

    private func resolvedURL(for setting: AidokuRunnerLegacySettingItem) -> URL? {
        if let urlString = setting.url, let url = URL(string: urlString) {
            return url
        }
        if
            let urlKey = setting.urlKey,
            let urlString = UserDefaults.standard.string(forKey: "\(source.key).\(urlKey)") ?? (urlKey == "url" ? currentBaseURL() : nil),
            let url = URL(string: urlString)
        {
            return url
        }
        return source.urls.first
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (navigationController?.topViewController ?? self).present(alert, animated: true)
    }

    private func selectedLanguages() -> [String] {
        if (source.config?.languageSelectType ?? .multiple) == .single,
           let language = UserDefaults.standard.string(forKey: "\(source.key).language"),
           !language.isEmpty {
            return [language]
        }
        return UserDefaults.standard.stringArray(forKey: "\(source.key).languages") ?? []
    }

    private func currentBaseURL() -> String {
        return UserDefaults.standard.string(forKey: "\(source.key).url") ?? source.urls.first?.absoluteString ?? ""
    }

    private func boolValue(for setting: AidokuRunnerLegacySettingItem) -> Bool {
        guard let key = setting.key else { return false }
        return UserDefaults.standard.bool(forKey: "\(source.key).\(key)")
    }

    private func detailText(for setting: AidokuRunnerLegacySettingItem) -> String? {
        if setting.type == "link" {
            return setting.subtitle ?? resolvedURL(for: setting)?.host
        }
        if setting.type == "button" {
            return setting.subtitle
        }
        guard let key = setting.key else { return nil }
        let defaultsKey = "\(source.key).\(key)"
        switch setting.type {
            case "switch", "toggle":
                return boolValue(for: setting) ? "On" : "Off"
            case "login":
                return isLoggedIn(setting) ? "Logged in" : setting.subtitle ?? "Not logged in"
            case "multi-select", "multi-single-select", "editable-list":
                let values = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
                return values.isEmpty ? "None" : values.joined(separator: ", ")
            case "select", "segment":
                let value = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
                return label(for: value, in: setting) ?? value
            default:
                return stringValue(forKey: defaultsKey)
        }
    }

    private func stringValue(forKey key: String) -> String {
        if let value = UserDefaults.standard.string(forKey: key) {
            return value
        }
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func options(for setting: AidokuRunnerLegacySettingItem) -> [(label: String, value: String)] {
        let values = setting.values ?? []
        let titles = setting.titles ?? []
        return values.enumerated().map { index, value in
            let title = index < titles.count ? titles[index] : value
            return (title, value)
        }
    }

    private func label(for value: String, in setting: AidokuRunnerLegacySettingItem) -> String? {
        return options(for: setting).first { $0.value == value }?.label
    }

    private func settingTitle(_ setting: AidokuRunnerLegacySettingItem) -> String {
        return setting.title ?? setting.key ?? setting.type
    }
}

final class LegacySourceHomeViewController: UITableViewController {
    private enum Row {
        case header(title: String?, subtitle: String?)
        case link(AidokuRunnerLegacyHomeLink)
        case manga(AidokuRunnerLegacyManga)
        case chapter(AidokuRunnerLegacyMangaWithChapter)
        case filter(AidokuRunnerLegacyHomeFilterItem)
        case listing(AidokuRunnerLegacyListing, title: String)
    }

    private let source: AidokuRunnerLegacySource
    private var rows: [Row] = []
    private var message = "Loading home..."
    private var isLoading = false

    init(source: AidokuRunnerLegacySource) {
        self.source = source
        super.init(style: .plain)
        title = source.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(loadHome), for: .valueChanged)
        loadHome()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.isEmpty ? 1 : rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HomeCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "HomeCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        cell.imageView?.image = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default

        guard !rows.isEmpty else {
            cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
            cell.textLabel?.text = isLoading ? "Loading..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        switch rows[indexPath.row] {
            case .header(let title, let subtitle):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
                cell.textLabel?.text = title ?? "Home"
                cell.detailTextLabel?.text = subtitle
                cell.accessoryType = .none
                cell.selectionStyle = .none
            case .link(let link):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = link.title
                cell.detailTextLabel?.text = link.subtitle ?? detailText(for: link.value)
                cell.accessoryType = link.value == nil ? .none : .disclosureIndicator
                cell.selectionStyle = link.value == nil ? .none : .default
                loadImage(for: link, into: cell, at: indexPath)
            case .manga(let manga):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = manga.title
                cell.detailTextLabel?.text = manga.authors?.joined(separator: ", ") ?? manga.description
                loadCover(for: manga, into: cell, at: indexPath)
            case .chapter(let entry):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = entry.manga.title
                cell.detailTextLabel?.text = chapterSubtitle(entry.chapter)
                if entry.chapter.locked {
                    cell.textLabel?.textColor = LegacyPalette.disabledText
                    cell.detailTextLabel?.textColor = LegacyPalette.disabledText
                    cell.accessoryType = .none
                    cell.selectionStyle = .none
                }
                loadCover(for: entry.manga, into: cell, at: indexPath)
            case .filter(let item):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = item.title
                cell.detailTextLabel?.text = "Search with this filter"
            case .listing(_, let title):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = title
                cell.detailTextLabel?.text = "View more"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !rows.isEmpty else { return }
        switch rows[indexPath.row] {
            case .header:
                return
            case .link(let link):
                open(linkValue: link.value)
            case .manga(let manga):
                navigationController?.pushViewController(
                    LegacyMangaDetailViewController(source: source, manga: manga),
                    animated: true
                )
            case .chapter(let entry):
                guard !entry.chapter.locked else {
                    showUnavailableChapterAlert(for: entry.chapter)
                    return
                }
                navigationController?.pushViewController(
                    LegacyReaderFactory.makeReader(source: source, manga: entry.manga, chapter: entry.chapter),
                    animated: true
                )
            case .filter(let item):
                navigationController?.pushViewController(
                    LegacyMangaListViewController(
                        source: source,
                        listing: nil,
                        initialFilters: item.values ?? [],
                        allowsEmptySearch: true,
                        titleOverride: item.title
                    ),
                    animated: true
                )
            case .listing(let listing, _):
                navigationController?.pushViewController(
                    LegacyMangaListViewController(source: source, listing: listing),
                    animated: true
                )
        }
    }

    @objc private func loadHome() {
        guard !isLoading else { return }
        isLoading = true
        message = "Loading home..."
        tableView.reloadData()
        source.runner.getHome { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            self.refreshControl?.endRefreshing()
            switch result {
                case .success(let home):
                    self.rows = self.rows(from: home)
                    self.message = self.rows.isEmpty ? "No home content." : ""
                case .failure(let error):
                    self.rows = []
                    self.message = error.localizedDescription
            }
            self.tableView.reloadData()
        }
    }

    private func rows(from home: AidokuRunnerLegacyHome) -> [Row] {
        var rows = [Row]()
        for component in home.components {
            if component.title != nil || component.subtitle != nil {
                rows.append(.header(title: component.title, subtitle: component.subtitle))
            }
            switch component.value {
                case .imageScroller(let links, _, _, _):
                    rows.append(contentsOf: links.map { .link($0) })
                case .bigScroller(let entries, _):
                    rows.append(contentsOf: entries.map { .manga($0) })
                case .scroller(let entries, let listing):
                    rows.append(contentsOf: entries.map { .link($0) })
                    if let listing = listing {
                        rows.append(.listing(listing, title: "More \(component.title ?? listing.name)"))
                    }
                case .mangaList(_, _, let entries, let listing):
                    rows.append(contentsOf: entries.map { .link($0) })
                    if let listing = listing {
                        rows.append(.listing(listing, title: "More \(component.title ?? listing.name)"))
                    }
                case .mangaChapterList(_, let entries, let listing):
                    rows.append(contentsOf: entries.map { .chapter($0) })
                    if let listing = listing {
                        rows.append(.listing(listing, title: "More \(component.title ?? listing.name)"))
                    }
                case .filters(let items):
                    rows.append(contentsOf: items.map { .filter($0) })
                case .links(let links):
                    rows.append(contentsOf: links.map { .link($0) })
            }
        }
        return rows
    }

    private func open(linkValue: AidokuRunnerLegacyHomeLink.Value?) {
        guard let linkValue = linkValue else { return }
        switch linkValue {
            case .url(let urlString):
                guard let url = URL(string: urlString, relativeTo: source.urls.first)?.absoluteURL else { return }
                navigationController?.pushViewController(
                    LegacySourceWebViewController(url: url, title: source.name),
                    animated: true
                )
            case .listing(let listing):
                navigationController?.pushViewController(
                    LegacyMangaListViewController(source: source, listing: listing),
                    animated: true
                )
            case .manga(let manga):
                navigationController?.pushViewController(
                    LegacyMangaDetailViewController(source: source, manga: manga),
                    animated: true
                )
        }
    }

    private func detailText(for value: AidokuRunnerLegacyHomeLink.Value?) -> String? {
        switch value {
            case .url(let url):
                return url
            case .listing(let listing):
                return listing.name
            case .manga(let manga):
                return manga.authors?.joined(separator: ", ") ?? manga.description
            case .none:
                return nil
        }
    }

    private func chapterSubtitle(_ chapter: AidokuRunnerLegacyChapter) -> String? {
        let subtitle = chapter.legacyFormattedSubtitle(sourceKey: source.key)
        return [chapter.legacyFormattedTitle, subtitle]
            .compactMap { value in
                guard let value = value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
    }

    private func showUnavailableChapterAlert(for chapter: AidokuRunnerLegacyChapter) {
        let alert = UIAlertController(
            title: "Chapter Unavailable",
            message: "\(chapter.legacyFormattedTitle) is marked unavailable by this source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func loadImage(for link: AidokuRunnerLegacyHomeLink, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let url = imageURL(for: link) else { return }
        LegacyImageLoader.shared.load(url: url, source: source, targetHeight: 130) { image in
            guard
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
    }

    private func loadCover(for manga: AidokuRunnerLegacyManga, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: manga.coverURLCandidates(relativeTo: source.urls.first),
            source: source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
    }

    private func imageURL(for link: AidokuRunnerLegacyHomeLink) -> URL? {
        if
            let imageUrl = link.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
            !imageUrl.isEmpty
        {
            if let url = URL(string: imageUrl), url.scheme != nil {
                return url
            }
            if let baseURL = source.urls.first {
                return URL(string: imageUrl, relativeTo: baseURL)?.absoluteURL
            }
            return URL(string: imageUrl)
        }

        if case .some(.manga(let manga)) = link.value {
            return manga.coverURL(relativeTo: source.urls.first)
        }
        return nil
    }
}

final class LegacyMangaListViewController: UITableViewController {
    private let source: AidokuRunnerLegacySource
    private let listing: AidokuRunnerLegacyListing?
    private let initialFilters: [AidokuRunnerLegacyFilterValue]
    private let allowsEmptySearch: Bool
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounceTimer: Timer?

    private var entries: [AidokuRunnerLegacyManga] = []
    private var availableFilters: [AidokuRunnerLegacyFilter] = []
    private var enabledFilters: [AidokuRunnerLegacyFilterValue] = []
    private var page = 1
    private var hasNextPage = false
    private var isLoading = false
    private var message = "Enter a search term."

    init(
        source: AidokuRunnerLegacySource,
        listing: AidokuRunnerLegacyListing?,
        initialFilters: [AidokuRunnerLegacyFilterValue] = [],
        allowsEmptySearch: Bool = false,
        titleOverride: String? = nil
    ) {
        self.source = source
        self.listing = listing
        self.initialFilters = initialFilters
        self.allowsEmptySearch = allowsEmptySearch
        super.init(style: .plain)
        title = titleOverride ?? listing?.name ?? "Search"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        if listing == nil {
            searchController.searchBar.placeholder = "Search manga"
            searchController.searchBar.delegate = self
            searchController.searchResultsUpdater = self
            searchController.obscuresBackgroundDuringPresentation = false
            navigationItem.searchController = searchController
            definesPresentationContext = true
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Filters",
                style: .plain,
                target: self,
                action: #selector(openFilters)
            )
            navigationItem.rightBarButtonItem?.isEnabled = false
            loadSavedFilters()
            if !initialFilters.isEmpty {
                enabledFilters = initialFilters
            }
            loadFilters()
        }

        if listing != nil {
            load(reset: true)
        } else if allowsEmptySearch || !initialFilters.isEmpty {
            load(reset: true)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if entries.isEmpty { return 1 }
        return entries.count + (hasNextPage ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MangaCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "MangaCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText

        if entries.isEmpty {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.row == entries.count {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading..." : "Load Next Page"
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
        }

        let manga = entries[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: manga.coverURLCandidates(relativeTo: source.urls.first),
            source: source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
        cell.textLabel?.text = manga.title
        cell.detailTextLabel?.text = manga.authors?.joined(separator: ", ") ?? manga.description
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if entries.isEmpty { return }
        if indexPath.row == entries.count {
            load(reset: false)
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entries[indexPath.row]),
            animated: true
        )
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !entries.isEmpty, indexPath.row >= max(0, entries.count - 3), hasNextPage {
            load(reset: false)
        }
    }

    @objc private func refresh() {
        load(reset: true)
    }

    private func load(reset: Bool) {
        guard !isLoading else { return }
        if reset {
            page = 1
            entries = []
            hasNextPage = false
        }
        isLoading = true
        message = "Loading..."
        tableView.reloadData()

        let completion: (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
                case .success(let pageResult):
                    if reset {
                        self.entries = pageResult.entries
                    } else {
                        self.entries.append(contentsOf: pageResult.entries)
                    }
                    self.hasNextPage = pageResult.hasNextPage
                    self.page += 1
                    self.message = self.entries.isEmpty ? "No manga found." : ""
                case .failure(let error):
                    self.message = error.localizedDescription
            }
            self.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }

        if let listing = listing {
            source.runner.getMangaList(listing: listing, page: page, completion: completion)
        } else {
            let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowsEmptySearch || !query.isEmpty || !enabledFilters.isEmpty else {
                isLoading = false
                message = "Enter a search term."
                refreshControl?.endRefreshing()
                tableView.reloadData()
                return
            }
            source.runner.getSearchMangaList(
                query: query.isEmpty ? nil : query,
                page: page,
                filters: enabledFilters,
                completion: completion
            )
        }
    }

    private func loadFilters() {
        availableFilters = source.staticFilters
        updateFilterButton()
        guard source.runner.features.dynamicFilters else { return }
        source.runner.getFilters { [weak self] result in
            guard let self = self else { return }
            if case .success(let filters) = result {
                var seen = Set(self.availableFilters.map { $0.id })
                self.availableFilters.append(contentsOf: filters.filter { seen.insert($0.id).inserted })
            }
            self.updateFilterButton()
        }
    }

    private func loadSavedFilters() {
        guard
            let data = UserDefaults.standard.data(forKey: filterStorageKey),
            let values = try? JSONDecoder().decode([AidokuRunnerLegacyFilterValue].self, from: data)
        else {
            return
        }
        enabledFilters = values
    }

    private func saveFilters() {
        if enabledFilters.isEmpty {
            UserDefaults.standard.removeObject(forKey: filterStorageKey)
        } else if let data = try? JSONEncoder().encode(enabledFilters) {
            UserDefaults.standard.set(data, forKey: filterStorageKey)
        }
    }

    private var filterStorageKey: String {
        return "AidokuLegacy.\(source.key).filters"
    }

    private func updateFilterButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !availableFilters.isEmpty
        let suffix = enabledFilters.isEmpty ? "" : " (\(enabledFilters.count))"
        navigationItem.rightBarButtonItem?.title = "Filters\(suffix)"
    }

    @objc private func openFilters() {
        let filterController = LegacyFilterViewController(
            filters: availableFilters,
            selectedFilters: enabledFilters
        ) { [weak self] values in
            guard let self = self else { return }
            self.enabledFilters = values
            self.saveFilters()
            self.updateFilterButton()
            self.load(reset: true)
        }
        let navigationController = UINavigationController(rootViewController: filterController)
        present(navigationController, animated: true)
    }
}

extension LegacyMangaListViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        load(reset: true)
    }
}

extension LegacyMangaListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard listing == nil else { return }
        searchDebounceTimer?.invalidate()
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard query.count >= 2 || allowsEmptySearch || !enabledFilters.isEmpty else {
            entries = []
            hasNextPage = false
            message = query.isEmpty ? "Enter a search term." : "Keep typing..."
            tableView.reloadData()
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.load(reset: true)
        }
    }
}

final class LegacyFilterViewController: UITableViewController {
    private let filters: [AidokuRunnerLegacyFilter]
    private var selectedFilters: [AidokuRunnerLegacyFilterValue]
    private let onApply: ([AidokuRunnerLegacyFilterValue]) -> Void

    init(
        filters: [AidokuRunnerLegacyFilter],
        selectedFilters: [AidokuRunnerLegacyFilterValue],
        onApply: @escaping ([AidokuRunnerLegacyFilterValue]) -> Void
    ) {
        self.filters = filters
        self.selectedFilters = selectedFilters
        self.onApply = onApply
        super.init(style: .grouped)
        title = "Filters"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = LegacyPalette.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Reset",
            style: .plain,
            target: self,
            action: #selector(resetFilters)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Apply",
            style: .done,
            target: self,
            action: #selector(applyFilters)
        )
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FilterCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "FilterCell")
        let filter = filters[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.textLabel?.text = filter.title ?? filter.id
        cell.detailTextLabel?.text = detailText(for: filter)
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator

        if case .note = filter.value {
            cell.selectionStyle = .none
            cell.accessoryType = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let filter = filters[indexPath.row]
        switch filter.value {
            case .text(let placeholder):
                editText(filter: filter, placeholder: placeholder)
            case .sort(let canAscend, let options, let defaultValue):
                let picker = LegacyFilterOptionPickerViewController(
                    title: filter.title ?? "Sort",
                    options: options.enumerated().map { (label: $0.element, value: String($0.offset)) },
                    selectedValues: Set([String(sortValue(for: filter)?.index ?? defaultValue?.index ?? 0)]),
                    allowsMultiple: false,
                    allowsExclusion: false
                ) { [weak self] included, _ in
                    guard let self = self, let selected = included.first, let index = Int(selected) else { return }
                    let ascending = canAscend ? (self.sortValue(for: filter)?.ascending ?? defaultValue?.ascending ?? false) : false
                    self.replace(.sort(id: filter.id, index: index, ascending: ascending))
                    self.tableView.reloadData()
                }
                navigationController?.pushViewController(picker, animated: true)
            case .check:
                cycleCheck(filter: filter)
            case .select(let select):
                let picker = LegacyFilterOptionPickerViewController(
                    title: filter.title ?? "Select",
                    options: select.options.enumerated().map {
                        let value = select.ids?.indices.contains($0.offset) == true ? select.ids![$0.offset] : $0.element
                        return (label: $0.element, value: value)
                    },
                    selectedValues: Set([selectValue(for: filter) ?? select.defaultValue ?? ""]),
                    allowsMultiple: false,
                    allowsExclusion: false
                ) { [weak self] included, _ in
                    guard let self = self, let value = included.first else { return }
                    self.replace(.select(id: filter.id, value: value))
                    self.tableView.reloadData()
                }
                navigationController?.pushViewController(picker, animated: true)
            case .multiselect(let multiSelect):
                let current = multiselectValue(for: filter)
                let picker = LegacyFilterOptionPickerViewController(
                    title: filter.title ?? "Select",
                    options: multiSelect.options.enumerated().map {
                        let value = multiSelect.ids?.indices.contains($0.offset) == true ? multiSelect.ids![$0.offset] : $0.element
                        return (label: $0.element, value: value)
                    },
                    selectedValues: Set(current?.included ?? multiSelect.defaultIncluded ?? []),
                    excludedValues: Set(current?.excluded ?? multiSelect.defaultExcluded ?? []),
                    allowsMultiple: true,
                    allowsExclusion: multiSelect.canExclude
                ) { [weak self] included, excluded in
                    guard let self = self else { return }
                    self.replace(.multiselect(id: filter.id, included: included, excluded: excluded))
                    self.tableView.reloadData()
                }
                navigationController?.pushViewController(picker, animated: true)
            case .note:
                break
            case .range:
                editRange(filter: filter)
        }
    }

    private func detailText(for filter: AidokuRunnerLegacyFilter) -> String? {
        switch filter.value {
            case .text:
                if case .text(_, let value)? = value(for: filter.id), !value.isEmpty {
                    return value
                }
                return "Any"
            case .sort(_, let options, let defaultValue):
                let value = sortValue(for: filter)
                let index = value?.index ?? defaultValue?.index ?? 0
                let label = options.indices.contains(index) ? options[index] : "Default"
                let ascending = value?.ascending ?? defaultValue?.ascending ?? false
                return ascending ? "\(label), ascending" : label
            case .check:
                if case .check(_, let value)? = value(for: filter.id) {
                    return value < 0 ? "Excluded" : value > 0 ? "Included" : "Any"
                }
                return "Any"
            case .select(let select):
                let value = selectValue(for: filter) ?? select.defaultValue
                guard let selected = value else { return "Default" }
                if let index = select.ids?.firstIndex(of: selected), select.options.indices.contains(index) {
                    return select.options[index]
                }
                return selected
            case .multiselect:
                let current = multiselectValue(for: filter)
                let included = current?.included.count ?? 0
                let excluded = current?.excluded.count ?? 0
                if included == 0 && excluded == 0 { return "Any" }
                return excluded == 0 ? "\(included) selected" : "\(included) selected, \(excluded) excluded"
            case .note(let note):
                return note
            case .range:
                if case .range(_, let from, let to)? = value(for: filter.id) {
                    return "\(from.map { String($0) } ?? "-") - \(to.map { String($0) } ?? "-")"
                }
                return "Any"
        }
    }

    private func editText(filter: AidokuRunnerLegacyFilter, placeholder: String?) {
        let alert = UIAlertController(title: filter.title ?? filter.id, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = placeholder
            if case .text(_, let value)? = self.value(for: filter.id) {
                textField.text = value
            }
        }
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            self.remove(id: filter.id)
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                self.remove(id: filter.id)
            } else {
                self.replace(.text(id: filter.id, value: text))
            }
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func editRange(filter: AidokuRunnerLegacyFilter) {
        let alert = UIAlertController(title: filter.title ?? filter.id, message: nil, preferredStyle: .alert)
        let current = rangeValue(for: filter)
        alert.addTextField { textField in
            textField.placeholder = "From"
            textField.keyboardType = .decimalPad
            textField.text = current?.from.map { String($0) }
        }
        alert.addTextField { textField in
            textField.placeholder = "To"
            textField.keyboardType = .decimalPad
            textField.text = current?.to.map { String($0) }
        }
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            self.remove(id: filter.id)
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in
            let from = alert.textFields?[0].text.flatMap(Float.init)
            let to = alert.textFields?[1].text.flatMap(Float.init)
            if from == nil && to == nil {
                self.remove(id: filter.id)
            } else {
                self.replace(.range(id: filter.id, from: from, to: to))
            }
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func cycleCheck(filter: AidokuRunnerLegacyFilter) {
        guard case .check(_, let canExclude, _) = filter.value else { return }
        let current: Int
        if case .check(_, let value)? = value(for: filter.id) {
            current = value
        } else {
            current = 0
        }
        let next: Int
        if current == 0 {
            next = 1
        } else if current == 1 && canExclude {
            next = -1
        } else {
            next = 0
        }
        if next == 0 {
            remove(id: filter.id)
        } else {
            replace(.check(id: filter.id, value: next))
        }
        tableView.reloadData()
    }

    private func value(for id: String) -> AidokuRunnerLegacyFilterValue? {
        return selectedFilters.first { $0.id == id }
    }

    private func sortValue(for filter: AidokuRunnerLegacyFilter) -> (index: Int, ascending: Bool)? {
        if case .sort(_, let index, let ascending)? = value(for: filter.id) {
            return (index, ascending)
        }
        return nil
    }

    private func selectValue(for filter: AidokuRunnerLegacyFilter) -> String? {
        if case .select(_, let value)? = value(for: filter.id) {
            return value
        }
        return nil
    }

    private func multiselectValue(for filter: AidokuRunnerLegacyFilter) -> (included: [String], excluded: [String])? {
        if case .multiselect(_, let included, let excluded)? = value(for: filter.id) {
            return (included, excluded)
        }
        return nil
    }

    private func rangeValue(for filter: AidokuRunnerLegacyFilter) -> (from: Float?, to: Float?)? {
        if case .range(_, let from, let to)? = value(for: filter.id) {
            return (from, to)
        }
        return nil
    }

    private func replace(_ value: AidokuRunnerLegacyFilterValue) {
        remove(id: value.id)
        selectedFilters.append(value)
    }

    private func remove(id: String) {
        selectedFilters.removeAll { $0.id == id }
    }

    @objc private func resetFilters() {
        selectedFilters = []
        tableView.reloadData()
    }

    @objc private func applyFilters() {
        onApply(selectedFilters)
        dismiss(animated: true)
    }
}

final class LegacyFilterOptionPickerViewController: UITableViewController {
    private let options: [(label: String, value: String)]
    private var selectedValues: Set<String>
    private var excludedValues: Set<String>
    private let allowsMultiple: Bool
    private let allowsExclusion: Bool
    private let onApply: ([String], [String]) -> Void

    init(
        title: String,
        options: [(label: String, value: String)],
        selectedValues: Set<String>,
        excludedValues: Set<String> = [],
        allowsMultiple: Bool,
        allowsExclusion: Bool,
        onApply: @escaping ([String], [String]) -> Void
    ) {
        self.options = options
        self.selectedValues = Set(selectedValues.filter { !$0.isEmpty })
        self.excludedValues = excludedValues
        self.allowsMultiple = allowsMultiple
        self.allowsExclusion = allowsExclusion
        self.onApply = onApply
        super.init(style: .plain)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = LegacyPalette.background
        if allowsMultiple {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(done)
            )
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OptionCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "OptionCell")
        let option = options[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.textLabel?.text = option.label
        if selectedValues.contains(option.value) {
            cell.accessoryType = .checkmark
            cell.detailTextLabel?.text = "Included"
        } else if excludedValues.contains(option.value) {
            cell.accessoryType = .detailButton
            cell.detailTextLabel?.text = "Excluded"
        } else {
            cell.accessoryType = .none
            cell.detailTextLabel?.text = nil
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let value = options[indexPath.row].value
        if allowsMultiple {
            cycle(value: value)
            tableView.reloadRows(at: [indexPath], with: .automatic)
        } else {
            onApply([value], [])
            navigationController?.popViewController(animated: true)
        }
    }

    private func cycle(value: String) {
        if selectedValues.contains(value) {
            selectedValues.remove(value)
            if allowsExclusion {
                excludedValues.insert(value)
            }
        } else if excludedValues.contains(value) {
            excludedValues.remove(value)
        } else {
            selectedValues.insert(value)
        }
    }

    @objc private func done() {
        onApply(Array(selectedValues), Array(excludedValues))
        navigationController?.popViewController(animated: true)
    }
}

final class LegacyChapterDownloadPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let sourceKey: String
    private let mangaKey: String
    private let chapters: [AidokuRunnerLegacyChapter]
    private let onSelect: (AidokuRunnerLegacyChapter) -> Void
    private var filteredChapters: [AidokuRunnerLegacyChapter] = []
    private let searchController = UISearchController(searchResultsController: nil)

    init(
        sourceKey: String,
        mangaKey: String,
        chapters: [AidokuRunnerLegacyChapter],
        onSelect: @escaping (AidokuRunnerLegacyChapter) -> Void
    ) {
        self.sourceKey = sourceKey
        self.mangaKey = mangaKey
        self.chapters = chapters
        self.filteredChapters = chapters
        self.onSelect = onSelect
        super.init(style: .plain)
        title = "Download Chapter"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search chapters"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(1, filteredChapters.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ChapterDownloadCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "ChapterDownloadCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        cell.imageView?.image = nil

        guard filteredChapters.indices.contains(indexPath.row) else {
            cell.textLabel?.text = "No matching chapters."
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let chapter = filteredChapters[indexPath.row]
        let downloaded = LegacyDownloadStore.shared.hasChapter(
            sourceKey: sourceKey,
            mangaKey: mangaKey,
            chapterKey: chapter.key
        )
        var subtitle = chapter.legacyFormattedSubtitle(sourceKey: sourceKey) ?? ""
        if downloaded {
            subtitle = subtitle.isEmpty ? "Downloaded" : "\(subtitle)\nDownloaded"
        }
        cell.textLabel?.text = chapter.legacyFormattedTitle
        cell.detailTextLabel?.text = subtitle.isEmpty ? nil : subtitle
        cell.accessoryType = downloaded ? .checkmark : .none
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard filteredChapters.indices.contains(indexPath.row) else { return }
        let chapter = filteredChapters[indexPath.row]
        navigationController?.popViewController(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [onSelect] in
            onSelect(chapter)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if query.isEmpty {
            filteredChapters = chapters
        } else {
            filteredChapters = chapters.filter { chapter in
                chapter.legacyFormattedTitle.lowercased().contains(query)
                    || (chapter.legacyFormattedSubtitle(sourceKey: sourceKey)?.lowercased().contains(query) ?? false)
                    || (chapter.language?.lowercased().contains(query) ?? false)
                    || chapter.key.lowercased().contains(query)
            }
        }
        tableView.reloadData()
    }
}

final class LegacyMangaDetailViewController: UITableViewController {
    private enum ReadingAction {
        case resume(LegacyHistoryEntry)
        case start(AidokuRunnerLegacyChapter)
    }

    private struct ChapterGroup {
        let title: String
        let chapters: [AidokuRunnerLegacyChapter]
    }

    private let source: AidokuRunnerLegacySource
    private var manga: AidokuRunnerLegacyManga
    private var isLoading = false
    private var isDownloading = false
    private var errorMessage: String?
    private lazy var bookmarkButton = UIBarButtonItem(title: "Add", style: .plain, target: self, action: #selector(toggleBookmark))
    private lazy var downloadButton = UIBarButtonItem(title: "Download", style: .plain, target: self, action: #selector(showDownloadOptions))
    private lazy var languageButton = UIBarButtonItem(title: "Language", style: .plain, target: self, action: #selector(showChapterLanguagePicker))

    init(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga) {
        self.source = source
        self.manga = manga
        super.init(style: .grouped)
        title = manga.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        navigationItem.rightBarButtonItems = [bookmarkButton, downloadButton, languageButton]
        updateBookmarkButton()
        updateLanguageButton()
        loadDetails()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2 + max(1, chapterGroups.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return "Details"
        }
        if section == 1 {
            return readingActions.isEmpty ? nil : "Reading"
        }
        let groups = chapterGroups
        if groups.isEmpty {
            return "Chapters"
        }
        return groups[section - 2].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1
        }
        if section == 1 {
            return readingActions.count
        }
        let groups = chapterGroups
        guard !groups.isEmpty else { return 1 }
        return groups[section - 2].chapters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DetailCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "DetailCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 3
        cell.imageView?.image = nil

        if indexPath.section == 0 {
            cell.imageView?.image = LegacyImageLoader.placeholder()
            LegacyImageLoader.shared.loadCover(
                urls: manga.coverURLCandidates(relativeTo: source.urls.first),
                source: source,
                targetHeight: 180
            ) { image in
                guard
                    let visibleIndexPath = tableView.indexPath(for: cell),
                    visibleIndexPath == indexPath
                else { return }
                cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
                cell.setNeedsLayout()
            }
            cell.textLabel?.text = manga.title
            cell.detailTextLabel?.text = errorMessage ?? manga.description ?? manga.authors?.joined(separator: ", ") ?? "No description."
            cell.accessoryType = .none
            return cell
        }

        if indexPath.section == 1 {
            let actions = readingActions
            guard actions.indices.contains(indexPath.row) else { return cell }
            switch actions[indexPath.row] {
                case .resume(let entry):
                    cell.textLabel?.text = "Resume Reading"
                    cell.detailTextLabel?.text = resumeSubtitle(for: entry)
                case .start(let chapter):
                    cell.textLabel?.text = "Read from First Chapter"
                    cell.detailTextLabel?.text = chapter.legacyFormattedTitle
            }
            cell.imageView?.image = nil
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }

        let groups = chapterGroups
        guard groups.indices.contains(indexPath.section - 2), !groups[indexPath.section - 2].chapters.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading chapters..." : "No chapters."
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            return cell
        }

        let chapter = groups[indexPath.section - 2].chapters[indexPath.row]
        cell.imageView?.image = nil
        cell.textLabel?.text = chapter.legacyFormattedTitle
        var subtitle = chapter.legacyFormattedSubtitle(sourceKey: source.key) ?? ""
        if LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            subtitle = subtitle.isEmpty ? "Downloaded" : "\(subtitle)\nDownloaded"
        }
        cell.detailTextLabel?.text = subtitle.isEmpty ? nil : subtitle
        if chapter.locked {
            cell.textLabel?.textColor = LegacyPalette.disabledText
            cell.detailTextLabel?.textColor = LegacyPalette.disabledText
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else {
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            let actions = readingActions
            guard actions.indices.contains(indexPath.row) else { return }
            switch actions[indexPath.row] {
                case .resume(let entry):
                    pushReader(chapter: entry.chapter, initialPageIndex: entry.pageIndex)
                case .start(let chapter):
                    pushReader(chapter: chapter)
            }
            return
        }
        guard
            indexPath.section >= 2,
            chapterGroups.indices.contains(indexPath.section - 2),
            chapterGroups[indexPath.section - 2].chapters.indices.contains(indexPath.row)
        else {
            return
        }
        let chapter = chapterGroups[indexPath.section - 2].chapters[indexPath.row]
        guard !chapter.locked else {
            showUnavailableChapterAlert(for: chapter)
            return
        }
        pushReader(chapter: chapter)
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard
            indexPath.section >= 2,
            chapterGroups.indices.contains(indexPath.section - 2),
            chapterGroups[indexPath.section - 2].chapters.indices.contains(indexPath.row)
        else {
            return nil
        }
        let chapter = chapterGroups[indexPath.section - 2].chapters[indexPath.row]
        guard !chapter.locked else { return nil }
        if LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            let remove = UITableViewRowAction(style: .destructive, title: "Remove Download") { [weak self] _, _ in
                guard let self = self else { return }
                LegacyDownloadStore.shared.delete(sourceKey: self.source.key, mangaKey: self.manga.key, chapterKey: chapter.key)
                self.tableView.reloadData()
            }
            return [remove]
        }
        let download = UITableViewRowAction(style: .normal, title: "Download") { [weak self] _, _ in
            self?.download(chapters: [chapter])
        }
        return [download]
    }

    private func loadDetails() {
        isLoading = true
        tableView.reloadData()
        source.runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                    case .success(let updatedManga):
                        self.manga = self.manga.mergedWithUpdate(updatedManga)
                        LegacyLibraryStore.shared.updateMangaMetadata(manga: self.manga, source: self.source)
                        LegacyHistoryStore.shared.updateMangaMetadata(manga: self.manga, source: self.source)
                        LegacyUpdateStore.shared.updateMangaMetadata(manga: self.manga, source: self.source)
                        self.errorMessage = nil
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                }
                self.updateBookmarkButton()
                self.updateLanguageButton()
                self.tableView.reloadData()
            }
        }
    }

    @objc private func toggleBookmark() {
        if LegacyLibraryStore.shared.contains(sourceKey: source.key, mangaKey: manga.key) {
            LegacyLibraryStore.shared.remove(sourceKey: source.key, mangaKey: manga.key)
        } else {
            LegacyLibraryStore.shared.add(manga: manga, source: source)
        }
        updateBookmarkButton()
    }

    private func updateBookmarkButton() {
        let inLibrary = LegacyLibraryStore.shared.contains(sourceKey: source.key, mangaKey: manga.key)
        bookmarkButton.title = inLibrary ? "Remove" : "Add"
    }

    private func updateLanguageButton() {
        let chapters = manga.chapters ?? []
        let languages = availableChapterLanguages(in: chapters)
        languageButton.isEnabled = languages.count > 1
        if let language = activeChapterLanguage(in: chapters) {
            languageButton.title = language.uppercased()
        } else {
            languageButton.title = "Language"
        }
    }

    @objc private func showChapterLanguagePicker() {
        let chapters = manga.chapters ?? []
        let languages = availableChapterLanguages(in: chapters)
        guard languages.count > 1 else { return }

        let selectedLanguage = activeChapterLanguage(in: chapters)
        let alert = UIAlertController(title: "Chapter Language", message: manga.title, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "All Languages", style: .default) { [weak self] _ in
            guard let self = self else { return }
            UserDefaults.standard.removeObject(forKey: self.chapterLanguageDefaultsKey)
            self.updateLanguageButton()
            self.tableView.reloadData()
        })
        for language in languages {
            let count = chapters.filter { $0.normalizedLanguage == language && !$0.locked }.count
            let suffix = selectedLanguage == language ? " Selected" : ""
            let title = "\(languageTitle(language)) (\(count))\(suffix)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                UserDefaults.standard.set(language, forKey: self.chapterLanguageDefaultsKey)
                self.updateLanguageButton()
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = languageButton
        }
        present(alert, animated: true)
    }

    @objc private func showDownloadOptions() {
        let readableChapters = displayChapters.filter { !$0.locked }
        guard !readableChapters.isEmpty else {
            showAlert(title: "No Chapters", message: "No readable chapters are available to download.")
            return
        }
        let alert = UIAlertController(title: "Download", message: manga.title, preferredStyle: .actionSheet)
        if let first = firstReadableChapter {
            alert.addAction(UIAlertAction(title: "Download First Chapter", style: .default) { [weak self] _ in
                self?.download(chapters: [first])
            })
        }
        alert.addAction(UIAlertAction(title: "Download Specific Chapter", style: .default) { [weak self] _ in
            self?.showSpecificChapterDownloadPicker(chapters: readableChapters)
        })
        alert.addAction(UIAlertAction(title: "Download All Chapters", style: .default) { [weak self] _ in
            self?.download(chapters: readableChapters)
        })
        alert.addAction(UIAlertAction(title: "Open Downloads", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(LegacyDownloadsViewController(), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = downloadButton
        }
        present(alert, animated: true)
    }

    private func showSpecificChapterDownloadPicker(chapters: [AidokuRunnerLegacyChapter]) {
        let picker = LegacyChapterDownloadPickerViewController(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapters: chapters
        ) { [weak self] chapter in
            self?.download(chapters: [chapter])
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func download(chapters: [AidokuRunnerLegacyChapter]) {
        guard !isDownloading else { return }
        let pending = chapters.filter {
            !LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: $0.key)
        }
        guard !pending.isEmpty else {
            showAlert(title: "Already Downloaded", message: "Selected chapters are already saved offline.")
            return
        }
        isDownloading = true
        downloadButton.isEnabled = false
        download(chapters: pending, index: 0, completed: 0)
    }

    private func download(chapters: [AidokuRunnerLegacyChapter], index: Int, completed: Int) {
        guard chapters.indices.contains(index) else {
            isDownloading = false
            downloadButton.isEnabled = true
            navigationItem.prompt = nil
            tableView.reloadData()
            showAlert(title: "Download Complete", message: "Saved \(completed) chapter(s) for offline reading.")
            return
        }
        let chapter = chapters[index]
        navigationItem.prompt = "Downloading \(index + 1) of \(chapters.count)..."
        LegacyDownloadManager.shared.download(
            source: source,
            manga: manga,
            chapter: chapter,
            progress: { [weak self] page, total in
                DispatchQueue.main.async {
                    self?.navigationItem.prompt = "Downloading \(index + 1) of \(chapters.count) - Page \(page)/\(total)"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                        case .success:
                            self.download(chapters: chapters, index: index + 1, completed: completed + 1)
                        case .failure(let error):
                            self.isDownloading = false
                            self.downloadButton.isEnabled = true
                            self.navigationItem.prompt = nil
                            self.tableView.reloadData()
                            self.showAlert(title: "Download Failed", message: error.localizedDescription)
                    }
                }
            }
        )
    }

    private var readingActions: [ReadingAction] {
        var actions: [ReadingAction] = []
        if let entry = LegacyHistoryStore.shared.latest(sourceKey: source.key, mangaKey: manga.key) {
            actions.append(.resume(entry))
        }
        if let chapter = firstReadableChapter {
            actions.append(.start(chapter))
        }
        return actions
    }

    private var displayChapters: [AidokuRunnerLegacyChapter] {
        let chapters = manga.chapters ?? []
        guard let language = activeChapterLanguage(in: chapters) else {
            return chapters
        }
        let filtered = chapters.filter { $0.normalizedLanguage == language || $0.normalizedLanguage == nil }
        return filtered.isEmpty ? chapters : filtered
    }

    private var chapterGroups: [ChapterGroup] {
        let chapters = displayChapters
        guard !chapters.isEmpty else { return [] }
        let grouped = Dictionary(grouping: chapters) { chapter -> String in
            return chapter.normalizedLanguage ?? "unknown"
        }
        guard grouped.keys.count > 1 else {
            return [ChapterGroup(title: "Chapters", chapters: chapters)]
        }
        let knownKeys = orderedLanguages(grouped.keys.filter { $0 != "unknown" })
        let orderedKeys = grouped.keys.contains("unknown") ? knownKeys + ["unknown"] : knownKeys
        return orderedKeys.map { key in
            ChapterGroup(title: "Chapters - \(languageTitle(key))", chapters: grouped[key] ?? [])
        }
    }

    private var firstReadableChapter: AidokuRunnerLegacyChapter? {
        let chapters = displayChapters.filter { !$0.locked }
        return chapters.sorted(by: legacyChapterAscending).first
    }

    private func selectedChapterLanguages() -> [String] {
        return (UserDefaults.standard.stringArray(forKey: "\(source.key).languages") ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var chapterLanguageDefaultsKey: String {
        return "\(source.key).\(manga.key).chapterLanguage"
    }

    private func activeChapterLanguage(in chapters: [AidokuRunnerLegacyChapter]) -> String? {
        let languages = availableChapterLanguages(in: chapters)
        guard !languages.isEmpty else { return nil }
        let savedLanguage = UserDefaults.standard.string(forKey: chapterLanguageDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let savedLanguage = savedLanguage, languages.contains(savedLanguage) {
            return savedLanguage
        }
        let selectedLanguages = selectedChapterLanguages()
        if
            selectedLanguages.count == 1,
            let selectedLanguage = selectedLanguages.first,
            languages.contains(selectedLanguage)
        {
            return selectedLanguage
        }
        return languages.count == 1 ? languages[0] : nil
    }

    private func availableChapterLanguages(in chapters: [AidokuRunnerLegacyChapter]) -> [String] {
        var languages: [String] = []
        for chapter in chapters {
            guard let language = chapter.normalizedLanguage else { continue }
            if !languages.contains(language) {
                languages.append(language)
            }
        }
        let selectedLanguages = selectedChapterLanguages()
        if !selectedLanguages.isEmpty {
            let selected = languages.filter { selectedLanguages.contains($0) }
            if !selected.isEmpty {
                languages = selected
            }
        }
        return orderedLanguages(languages)
    }

    private func orderedLanguages(_ languages: [String]) -> [String] {
        let preferredLanguages = preferredChapterLanguages()
        return languages.sorted { lhs, rhs in
            let lhsIndex = preferredLanguages.firstIndex(of: lhs) ?? Int.max
            let rhsIndex = preferredLanguages.firstIndex(of: rhs) ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return languageTitle(lhs).localizedCaseInsensitiveCompare(languageTitle(rhs)) == .orderedAscending
        }
    }

    private func preferredChapterLanguages() -> [String] {
        var values: [String] = []
        for identifier in Locale.preferredLanguages {
            let normalizedIdentifier = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if !values.contains(normalizedIdentifier) {
                values.append(normalizedIdentifier)
            }
            let locale = Locale(identifier: identifier)
            if
                let languageCode = locale.languageCode?.lowercased(),
                !values.contains(languageCode)
            {
                values.append(languageCode)
            }
        }
        for language in selectedChapterLanguages() where !values.contains(language) {
            values.append(language)
        }
        return values
    }

    private func languageTitle(_ language: String) -> String {
        if language == "unknown" {
            return "Unknown Language"
        }
        return Locale.current.localizedString(forIdentifier: language) ?? language.uppercased()
    }

    private func legacyChapterAscending(_ lhs: AidokuRunnerLegacyChapter, _ rhs: AidokuRunnerLegacyChapter) -> Bool {
        if let lhsVolume = lhs.volumeNumber, let rhsVolume = rhs.volumeNumber, lhsVolume != rhsVolume {
            return lhsVolume < rhsVolume
        }
        if lhs.volumeNumber != nil && rhs.volumeNumber == nil {
            return true
        }
        if lhs.volumeNumber == nil && rhs.volumeNumber != nil {
            return false
        }
        if let lhsChapter = lhs.chapterNumber, let rhsChapter = rhs.chapterNumber, lhsChapter != rhsChapter {
            return lhsChapter < rhsChapter
        }
        if lhs.chapterNumber != nil && rhs.chapterNumber == nil {
            return true
        }
        if lhs.chapterNumber == nil && rhs.chapterNumber != nil {
            return false
        }
        if let lhsDate = lhs.dateUploaded, let rhsDate = rhs.dateUploaded, lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.legacyFormattedTitle.localizedStandardCompare(rhs.legacyFormattedTitle) == .orderedAscending
    }

    private func resumeSubtitle(for entry: LegacyHistoryEntry) -> String {
        if entry.pageCount > 0 {
            return "\(entry.chapter.legacyFormattedTitle) - Page \(entry.pageIndex + 1) of \(entry.pageCount)"
        }
        return entry.chapter.legacyFormattedTitle
    }

    private func pushReader(chapter: AidokuRunnerLegacyChapter, initialPageIndex: Int = 0) {
        let reader = LegacyReaderFactory.makeReader(
            source: source,
            manga: manga,
            chapter: chapter,
            initialPageIndex: initialPageIndex
        )
        navigationController?.pushViewController(reader, animated: true)
    }

    private func showUnavailableChapterAlert(for chapter: AidokuRunnerLegacyChapter) {
        let alert = UIAlertController(
            title: "Chapter Unavailable",
            message: "\(chapter.legacyFormattedTitle) is marked unavailable by this source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private extension AidokuRunnerLegacyImageRequest {
    func urlRequest(source: AidokuRunnerLegacySource? = nil, fallbackURL: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        request.applyLegacyImageDefaults(for: url)
        request.applyLegacyRefererIfNeeded(source: source, imageURL: fallbackURL ?? url)
        return request
    }
}

private extension URLRequest {
    mutating func applyLegacyImageDefaults(for url: URL) {
        if value(forHTTPHeaderField: "User-Agent") == nil {
            setValue(aidokuLegacyImageUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if value(forHTTPHeaderField: "Accept") == nil {
            setValue(aidokuLegacyImageAcceptHeader, forHTTPHeaderField: "Accept")
        }
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.cookies(for: url) ?? [])
        for (key, value) in cookieHeaders {
            if key == "Cookie", let existing = self.value(forHTTPHeaderField: "Cookie"), !existing.isEmpty {
                setValue(value + "; " + existing, forHTTPHeaderField: key)
            } else {
                setValue(value, forHTTPHeaderField: key)
            }
        }
        timeoutInterval = 30
    }

    mutating func applyLegacyRefererIfNeeded(source: AidokuRunnerLegacySource?, imageURL: URL) {
        guard value(forHTTPHeaderField: "Referer") == nil else { return }
        let refererURL = source?.urls.first ?? imageURL
        guard let scheme = refererURL.scheme, let host = refererURL.host else { return }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = refererURL.port
        guard let origin = components.url?.absoluteString else { return }
        setValue(origin.hasSuffix("/") ? origin : origin + "/", forHTTPHeaderField: "Referer")
    }
}

private func legacyFallbackImageRequest(url: URL, source: AidokuRunnerLegacySource? = nil) -> URLRequest {
    var request = URLRequest(url: url)
    request.applyLegacyImageDefaults(for: url)
    request.applyLegacyRefererIfNeeded(source: source, imageURL: url)
    if aidokuLegacyIsHitomiImage(url: url, source: source), request.value(forHTTPHeaderField: "Origin") == nil {
        request.setValue("https://hitomi.la", forHTTPHeaderField: "Origin")
    }
    return request
}

private func legacyFallbackImageRequests(
    url: URL,
    source: AidokuRunnerLegacySource?,
    excluding primaryRequest: URLRequest? = nil
) -> [URLRequest] {
    var requests: [URLRequest] = []
        let urls = [url]
            + legacyMangaDexCoverFallbackURLs(from: url)
            + legacyHitomiThumbnailFallbackURLs(from: url)
    for candidateURL in urls {
        let request = legacyFallbackImageRequest(url: candidateURL, source: source)
        if let primaryRequest = primaryRequest, legacyImageRequestsMatch(request, primaryRequest) {
            continue
        }
        guard !requests.contains(where: { legacyImageRequestsMatch($0, request) }) else {
            continue
        }
        requests.append(request)
    }
    return requests
}

private func legacyImageRequestsMatch(_ lhs: URLRequest, _ rhs: URLRequest) -> Bool {
    return lhs.url == rhs.url
        && lhs.httpMethod == rhs.httpMethod
        && lhs.httpBody == rhs.httpBody
        && lhs.allHTTPHeaderFields == rhs.allHTTPHeaderFields
}

private func aidokuLegacyIsHitomiImage(url: URL, source: AidokuRunnerLegacySource?) -> Bool {
    let sourceText = [source?.key, source?.name]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    if sourceText.contains("hitomi") {
        return true
    }
    let host = url.host?.lowercased() ?? ""
    return host.contains("hitomi.la") || host.contains("gold-usergeneratedcontent.net")
}

private func legacyMangaDexCoverFallbackURLs(from url: URL) -> [URL] {
    let host = url.host?.lowercased() ?? ""
    let pathComponents = url.pathComponents
    guard
        host.contains("mangadex.org"),
        let coversIndex = pathComponents.firstIndex(where: { $0.lowercased() == "covers" }),
        pathComponents.indices.contains(coversIndex + 2)
    else {
        return []
    }

    let mangaID = pathComponents[coversIndex + 1]
    let fileName = pathComponents[coversIndex + 2]
    let fileNames = legacyMangaDexCoverFileNameCandidates(from: fileName)
    var urls: [URL] = []
    for host in ["uploads.mangadex.org", "mangadex.org"] {
        for fileName in fileNames {
            guard let candidateURL = URL(string: "https://\(host)/covers/\(mangaID)/\(fileName)") else { continue }
            if candidateURL != url, !urls.contains(candidateURL) {
                urls.append(candidateURL)
            }
        }
    }
    return urls
}

private func legacyMangaDexCoverFileNameCandidates(from fileName: String) -> [String] {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let withoutSizeSuffix = trimmed
        .replacingOccurrences(of: ".512.jpg", with: ".jpg", options: [.caseInsensitive])
        .replacingOccurrences(of: ".256.jpg", with: ".jpg", options: [.caseInsensitive])
    var candidates: [String] = []
    for candidate in [
        trimmed,
        withoutSizeSuffix,
        legacyPath(withoutSizeSuffix, insertingSuffixBeforeExtension: ".512"),
        legacyPath(withoutSizeSuffix, insertingSuffixBeforeExtension: ".256")
    ] where !candidates.contains(candidate) {
        candidates.append(candidate)
    }
    return candidates
}

private func legacyHitomiThumbnailFallbackURLs(from url: URL) -> [URL] {
    guard aidokuLegacyIsHitomiImage(url: url, source: nil) else { return [] }
    let path = url.path
    let lowercasedPath = path.lowercased()
    guard lowercasedPath.contains("/avif") || url.pathExtension.lowercased() == "avif" else { return [] }

    let replacements = [
        (from: "/avifbigtn/", to: "/webpbigtn/", pathExtension: "webp"),
        (from: "/avifsmalltn/", to: "/webpsmalltn/", pathExtension: "webp"),
        (from: "/avifbigtn/", to: "/bigtn/", pathExtension: "jpg"),
        (from: "/avifsmalltn/", to: "/smalltn/", pathExtension: "jpg")
    ]

    var paths = [path]
    for replacement in replacements {
        let replacedPath = path.replacingOccurrences(
            of: replacement.from,
            with: replacement.to,
            options: [.caseInsensitive]
        )
        guard replacedPath != path else { continue }
        let pathWithExtension = legacyPath(replacedPath, replacingExtensionWith: replacement.pathExtension)
        if !paths.contains(pathWithExtension) {
            paths.append(pathWithExtension)
        }
    }

    guard let currentHost = url.host?.lowercased() else { return [] }
    let hosts = legacyHitomiThumbnailHosts(for: currentHost)
    var urls: [URL] = []
    for host in hosts {
        for candidatePath in paths {
            guard host != currentHost || candidatePath != path else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = host
            components?.path = candidatePath
            guard let candidateURL = components?.url, !urls.contains(candidateURL) else { continue }
            urls.append(candidateURL)
        }
    }
    return urls
}

private func legacyHitomiThumbnailHosts(for currentHost: String) -> [String] {
    var hosts = [currentHost]
    for host in ["tn.gold-usergeneratedcontent.net", "atn.gold-usergeneratedcontent.net", "tn.hitomi.la"] {
        if !hosts.contains(host) {
            hosts.append(host)
        }
    }
    return hosts
}

private func legacyPath(_ path: String, replacingExtensionWith pathExtension: String) -> String {
    let basePath = (path as NSString).deletingPathExtension
    return basePath + "." + pathExtension
}

private func legacyPath(_ path: String, insertingSuffixBeforeExtension suffix: String) -> String {
    let basePath = (path as NSString).deletingPathExtension
    let pathExtension = (path as NSString).pathExtension
    guard !pathExtension.isEmpty else { return path + suffix }
    return basePath + suffix + "." + pathExtension
}

private enum LegacyReaderFactory {
    static func makeReader(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        initialPageIndex: Int = 0
    ) -> UIViewController {
        let mode = LegacyReaderMode.current
        if mode.usesPagedReader {
            return LegacyPagedReaderViewController(
                source: source,
                manga: manga,
                chapter: chapter,
                mode: mode,
                initialPageIndex: initialPageIndex
            )
        }
        return LegacyReaderViewController(
            source: source,
            manga: manga,
            chapter: chapter,
            initialPageIndex: initialPageIndex
        )
    }
}

private final class LegacyReaderViewController: UITableViewController, UIGestureRecognizerDelegate {
    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let chapter: AidokuRunnerLegacyChapter
    private let initialPageIndex: Int
    private var pages: [AidokuRunnerLegacyPage] = []
    private var message = "Loading pages..."
    private var didScrollToInitialPage = false
    private var currentPageIndex: Int?
    private var lastSavedHistoryPageIndex: Int?
    private var lastHistorySaveDate = Date.distantPast
    private var pendingHistorySaveWorkItem: DispatchWorkItem?
    private let overlayView = LegacyReaderOverlayView()
    private var barsHidden = false
    private var didShowTapOverlay = false
    private var appStateObservers: [NSObjectProtocol] = []
    private var didTrimVisibleImagesForBackground = false
    private var temporaryPageDirectories: [URL] = []
    private var fitToScreen: Bool {
        return LegacyReaderMode.current == .verticalFit
    }
    private var readerPageSize: CGSize {
        let insets = tableView.adjustedContentInset
        let height = max(320, tableView.bounds.height - insets.top - insets.bottom)
        let width = max(1, tableView.bounds.width)
        return CGSize(width: width, height: height)
    }

    init(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        initialPageIndex: Int = 0
    ) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
        self.initialPageIndex = initialPageIndex
        super.init(style: .plain)
        title = chapter.legacyFormattedTitle
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in appStateObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.isTranslucent = false
        tableView.backgroundColor = UIColor.black
        tableView.separatorStyle = .none
        tableView.register(LegacyPageImageCell.self, forCellReuseIdentifier: "PageImageCell")
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        tableView.addGestureRecognizer(tapRecognizer)
        registerAppStateObservers()
        updateReaderMode()
        loadPages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enforceReaderContainer()
        navigationController?.setNavigationBarHidden(barsHidden, animated: animated)
        updateReaderMode()
        installOverlayIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installOverlayIfNeeded()
        showTapOverlayIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enforceReaderContainer(relayout: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        trimReaderMemory(keepCurrentPage: false)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tabBarController?.tabBar.isHidden = false
        overlayView.removeFromSuperview()
    }

    override var prefersStatusBarHidden: Bool {
        return barsHidden
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.updateReaderMode()
            self.tableView.reloadData()
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        trimReaderMemory(keepCurrentPage: true)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if fitToScreen {
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pages.isEmpty ? 1 : pages.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if fitToScreen, isImagePage(at: indexPath) {
            return readerPageSize.height
        }
        return pages.isEmpty ? 80 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if fitToScreen, isImagePage(at: indexPath) {
            return readerPageSize.height
        }
        return pages.isEmpty ? 80 : 900
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if pages.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReaderMessage")
                ?? UITableViewCell(style: .default, reuseIdentifier: "ReaderMessage")
            cell.backgroundColor = UIColor.black
            cell.textLabel?.textColor = UIColor.white
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.text = message
            cell.selectionStyle = .none
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "PageImageCell", for: indexPath) as! LegacyPageImageCell
        cell.onHeightChange = { [weak tableView] in
            tableView?.beginUpdates()
            tableView?.endUpdates()
        }
        cell.configure(
            page: pages[indexPath.row],
            source: source,
            availableSize: readerPageSize,
            fitsViewport: fitToScreen
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !pages.isEmpty, indexPath.row < pages.count {
            currentPageIndex = indexPath.row
            recordHistory(pageIndex: indexPath.row, force: false)
            updatePageHUD()
        }

        preloadPages(around: indexPath.row, includeCurrent: false)
    }

    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let pageCell = cell as? LegacyPageImageCell else { return }
        let loadID = pageCell.currentLoadID
        DispatchQueue.main.asyncAfter(deadline: .now() + aidokuLegacyReaderRetainedPageDelay()) { [weak tableView, weak pageCell] in
            guard let tableView = tableView, let pageCell = pageCell else { return }
            guard tableView.indexPath(for: pageCell) == nil else { return }
            pageCell.releaseDecodedImage(ifLoadID: loadID)
        }
    }

    private func loadPages() {
        if let downloadedPages = LegacyDownloadStore.shared.pages(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            setPages(downloadedPages)
            message = downloadedPages.isEmpty ? "No downloaded pages." : ""
            tableView.reloadData()
            scrollToInitialPageIfNeeded()
            updatePageHUD()
            return
        }
        guard !chapter.locked else {
            pages = []
            message = "\(chapter.legacyFormattedTitle) is unavailable from this source."
            tableView.reloadData()
            return
        }
        source.runner.getPageList(manga: manga, chapter: chapter) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                    case .success(let pages):
                        self.setPages(pages)
                        self.message = pages.isEmpty ? "No pages." : ""
                    case .failure(let error):
                        self.message = self.readerMessage(for: error)
                }
                self.tableView.reloadData()
                self.scrollToInitialPageIfNeeded()
                self.updatePageHUD()
            }
        }
    }

    private func updateReaderMode() {
        tableView.isPagingEnabled = fitToScreen
        tableView.decelerationRate = fitToScreen ? .fast : .normal
    }

    private func setPages(_ newPages: [AidokuRunnerLegacyPage]) {
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
        temporaryPageDirectories = []
        let prepared = aidokuLegacyPreparePagesForLowMemory(newPages)
        pages = prepared.pages
        temporaryPageDirectories = prepared.temporaryDirectories
        let warmupPageIndex = pages.indices.contains(initialPageIndex) ? initialPageIndex : 0
        preloadPages(around: warmupPageIndex, includeCurrent: true)
    }

    private func preloadPages(around pageIndex: Int, includeCurrent: Bool) {
        let preloadCount = aidokuLegacyReaderPrefetchCount()
        guard preloadCount > 0 || includeCurrent else { return }
        var candidateIndexes = includeCurrent ? [pageIndex] : []
        if preloadCount > 0 {
            candidateIndexes += (1...preloadCount).flatMap { offset in
                [pageIndex + offset, pageIndex - offset]
            }
        }
        for candidateIndex in candidateIndexes where pages.indices.contains(candidateIndex) {
            guard case .url(let url, let context) = pages[candidateIndex].content else { continue }
            LegacyReaderImagePipeline.shared.preload(url: url, context: context, source: source)
        }
    }

    @objc private func toggleBars() {
        barsHidden.toggle()
        navigationController?.setNavigationBarHidden(barsHidden, animated: true)
        overlayView.setControlsHidden(barsHidden, animated: true)
        enforceReaderContainer()
        UIView.animate(withDuration: 0.2, animations: {
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            self.updateReaderMode()
            if self.fitToScreen {
                self.tableView.reloadData()
            }
        })
    }

    @objc private func handleReaderTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: view)
        if location.x < view.bounds.width * 0.33 {
            movePage(delta: -1)
        } else if location.x > view.bounds.width * 0.67 {
            movePage(delta: 1)
        } else {
            toggleBars()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return shouldHandleReaderTap(from: touch)
    }

    private func shouldHandleReaderTap(from touch: UITouch) -> Bool {
        var view = touch.view
        while let currentView = view {
            if let zoomableView = currentView as? LegacyZoomableImageView {
                return !zoomableView.isZoomed
            }
            view = currentView.superview
        }
        return true
    }

    private func movePage(delta: Int) {
        guard !pages.isEmpty else { return }
        let current = currentPageIndex ?? tableView.indexPathsForVisibleRows?.first?.row ?? 0
        let next = min(max(current + delta, 0), pages.count - 1)
        guard next != current else {
            overlayView.showGuide(modeTitle: LegacyReaderMode.current.title)
            return
        }
        tableView.scrollToRow(at: IndexPath(row: next, section: 0), at: .top, animated: true)
        currentPageIndex = next
        recordHistory(pageIndex: next, force: false)
        updatePageHUD()
    }

    private func jumpToPage(_ pageIndex: Int, animated: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        tableView.scrollToRow(at: IndexPath(row: pageIndex, section: 0), at: .top, animated: animated)
        currentPageIndex = pageIndex
        preloadPages(around: pageIndex, includeCurrent: true)
        recordHistory(pageIndex: pageIndex, force: true)
        updatePageHUD()
    }

    private func installOverlayIfNeeded() {
        guard overlayView.superview == nil else { return }
        guard let hostView = navigationController?.view ?? view else { return }
        overlayView.onPageSelected = { [weak self] pageIndex in
            self?.jumpToPage(pageIndex, animated: false)
        }
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
        overlayView.setControlsHidden(barsHidden, animated: false)
        updatePageHUD()
    }

    private func showTapOverlayIfNeeded() {
        guard aidokuLegacyReaderShowsTapZones(), !didShowTapOverlay else { return }
        didShowTapOverlay = true
        overlayView.showGuide(modeTitle: LegacyReaderMode.current.title)
    }

    private func updatePageHUD() {
        overlayView.updatePage(index: currentPageIndex, count: pages.count)
    }

    private func registerAppStateObservers() {
        let center = NotificationCenter.default
        appStateObservers.append(
            center.addObserver(forName: .legacyMemoryTrimRequested, object: nil, queue: .main) { [weak self] _ in
                self?.trimReaderMemory(keepCurrentPage: true)
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppWillEnterForeground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppWillEnterForeground()
            }
        )
    }

    private func handleAppDidEnterBackground() {
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        didTrimVisibleImagesForBackground = true
        trimReaderMemory(keepCurrentPage: false)
    }

    private func handleAppWillEnterForeground() {
        guard didTrimVisibleImagesForBackground else { return }
        didTrimVisibleImagesForBackground = false
        let pageIndex = currentPageIndex
        tableView.reloadData()
        guard let pageIndex = pageIndex, pages.indices.contains(pageIndex) else { return }
        DispatchQueue.main.async {
            self.tableView.scrollToRow(at: IndexPath(row: pageIndex, section: 0), at: .top, animated: false)
            self.currentPageIndex = pageIndex
            self.updatePageHUD()
        }
    }

    private func trimReaderMemory(keepCurrentPage: Bool) {
        let current = keepCurrentPage ? currentPageIndex : nil
        for cell in tableView.visibleCells {
            guard let pageCell = cell as? LegacyPageImageCell else { continue }
            let indexPath = tableView.indexPath(for: cell)
            if indexPath?.row != current {
                pageCell.releaseDecodedImage()
            }
        }
        aidokuLegacyTrimVolatileCaches()
    }

    private func enforceReaderContainer(relayout: Bool = true) {
        tabBarController?.tabBar.isHidden = true
        guard relayout else { return }
        tabBarController?.view.setNeedsLayout()
        tabBarController?.view.layoutIfNeeded()
    }

    private func isImagePage(at indexPath: IndexPath) -> Bool {
        guard !pages.isEmpty, pages.indices.contains(indexPath.row) else { return false }
        switch pages[indexPath.row].content {
            case .url(_, _), .image(_):
                return true
            case .text(_), .zipFile(_, _):
                return false
        }
    }

    private func readerMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("missing chapter data") {
            return "This chapter is unavailable from the source."
        }
        return message
    }

    private func scrollToInitialPageIfNeeded() {
        guard !didScrollToInitialPage, pages.indices.contains(initialPageIndex) else { return }
        didScrollToInitialPage = true
        DispatchQueue.main.async {
            self.tableView.scrollToRow(
                at: IndexPath(row: self.initialPageIndex, section: 0),
                at: .top,
                animated: false
            )
            self.currentPageIndex = self.initialPageIndex
            self.updatePageHUD()
        }
    }

    private func recordHistory(pageIndex: Int, force: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        let now = Date()
        if force {
            pendingHistorySaveWorkItem?.cancel()
            pendingHistorySaveWorkItem = nil
        } else {
            if lastSavedHistoryPageIndex == pageIndex {
                return
            }
            let saveDelay = 2 - now.timeIntervalSince(lastHistorySaveDate)
            if saveDelay > 0 {
                pendingHistorySaveWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard self?.currentPageIndex == pageIndex else { return }
                    self?.recordHistory(pageIndex: pageIndex, force: true)
                }
                pendingHistorySaveWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: workItem)
                return
            }
        }
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        LegacyHistoryStore.shared.update(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        LegacyReaderSessionStore.shared.save(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        lastSavedHistoryPageIndex = pageIndex
        lastHistorySaveDate = now
    }
}

private final class LegacyPagedReaderViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let chapter: AidokuRunnerLegacyChapter
    private let mode: LegacyReaderMode
    private let initialPageIndex: Int
    private var collectionView: UICollectionView!
    private var pages: [AidokuRunnerLegacyPage] = []
    private var message = "Loading pages..."
    private var didScrollToInitialPage = false
    private var currentPageIndex: Int?
    private var lastSavedHistoryPageIndex: Int?
    private var lastHistorySaveDate = Date.distantPast
    private var pendingHistorySaveWorkItem: DispatchWorkItem?
    private let overlayView = LegacyReaderOverlayView()
    private var barsHidden = false
    private var didShowTapOverlay = false
    private var appStateObservers: [NSObjectProtocol] = []
    private var didTrimVisibleImagesForBackground = false
    private var temporaryPageDirectories: [URL] = []

    init(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        mode: LegacyReaderMode,
        initialPageIndex: Int = 0
    ) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
        self.mode = mode
        self.initialPageIndex = initialPageIndex
        super.init(nibName: nil, bundle: nil)
        title = chapter.legacyFormattedTitle
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in appStateObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.isTranslucent = false
        view.backgroundColor = UIColor.black

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor.black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.alwaysBounceVertical = false
        if aidokuLegacyIsLowMemoryMode() {
            collectionView.isPrefetchingEnabled = false
        }
        collectionView.register(LegacyPagedImageCell.self, forCellWithReuseIdentifier: "PagedImageCell")
        collectionView.register(LegacyPagedMessageCell.self, forCellWithReuseIdentifier: "PagedMessageCell")
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        collectionView.addGestureRecognizer(tapRecognizer)

        registerAppStateObservers()
        loadPages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enforceReaderContainer()
        navigationController?.setNavigationBarHidden(barsHidden, animated: animated)
        installOverlayIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installOverlayIfNeeded()
        showTapOverlayIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enforceReaderContainer(relayout: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        trimReaderMemory(keepCurrentPage: false)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tabBarController?.tabBar.isHidden = false
        overlayView.removeFromSuperview()
    }

    override var prefersStatusBarHidden: Bool {
        return barsHidden
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        let current = currentPageIndex
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.reloadData()
            if let current = current {
                self.scrollTo(pageIndex: current, animated: false)
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        trimReaderMemory(keepCurrentPage: true)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        collectionView?.collectionViewLayout.invalidateLayout()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return pages.isEmpty ? 1 : pages.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        return collectionView.bounds.size
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if pages.isEmpty {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: "PagedMessageCell",
                for: indexPath
            ) as! LegacyPagedMessageCell
            cell.configure(message)
            return cell
        }

        let pageIndex = pageIndex(forVisualIndex: indexPath.item)
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "PagedImageCell",
            for: indexPath
        ) as! LegacyPagedImageCell
        cell.configure(page: pages[pageIndex], source: source)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard !pages.isEmpty else { return }
        let pageIndex = pageIndex(forVisualIndex: indexPath.item)
        currentPageIndex = pageIndex
        recordHistory(pageIndex: pageIndex, force: false)
        updatePageHUD()
        preloadPages(around: pageIndex, includeCurrent: false)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let pageCell = cell as? LegacyPagedImageCell else { return }
        let loadID = pageCell.currentLoadID
        DispatchQueue.main.asyncAfter(deadline: .now() + aidokuLegacyReaderRetainedPageDelay()) { [weak collectionView, weak pageCell] in
            guard let collectionView = collectionView, let pageCell = pageCell else { return }
            guard collectionView.indexPath(for: pageCell) == nil else { return }
            pageCell.releaseDecodedImage(ifLoadID: loadID)
        }
    }

    private func loadPages() {
        if let downloadedPages = LegacyDownloadStore.shared.pages(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            setPages(downloadedPages)
            message = downloadedPages.isEmpty ? "No downloaded pages." : ""
            collectionView.reloadData()
            scrollToInitialPageIfNeeded()
            updatePageHUD()
            return
        }
        guard !chapter.locked else {
            pages = []
            message = "\(chapter.legacyFormattedTitle) is unavailable from this source."
            collectionView.reloadData()
            return
        }
        source.runner.getPageList(manga: manga, chapter: chapter) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                    case .success(let pages):
                        self.setPages(pages)
                        self.message = pages.isEmpty ? "No pages." : ""
                    case .failure(let error):
                        self.message = self.readerMessage(for: error)
                }
                self.collectionView.reloadData()
                self.scrollToInitialPageIfNeeded()
                self.updatePageHUD()
            }
        }
    }

    private func setPages(_ newPages: [AidokuRunnerLegacyPage]) {
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
        temporaryPageDirectories = []
        let prepared = aidokuLegacyPreparePagesForLowMemory(newPages)
        pages = prepared.pages
        temporaryPageDirectories = prepared.temporaryDirectories
        let warmupPageIndex = pages.indices.contains(initialPageIndex) ? initialPageIndex : 0
        preloadPages(around: warmupPageIndex, includeCurrent: true)
    }

    private func scrollToInitialPageIfNeeded() {
        guard !didScrollToInitialPage, pages.indices.contains(initialPageIndex) else { return }
        didScrollToInitialPage = true
        DispatchQueue.main.async {
            self.collectionView.layoutIfNeeded()
            self.scrollTo(pageIndex: self.initialPageIndex, animated: false)
            self.currentPageIndex = self.initialPageIndex
            self.recordHistory(pageIndex: self.initialPageIndex, force: true)
            self.updatePageHUD()
        }
    }

    private func scrollTo(pageIndex: Int, animated: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: visualIndex(forPageIndex: pageIndex), section: 0),
            at: .centeredHorizontally,
            animated: animated
        )
    }

    private func visualIndex(forPageIndex pageIndex: Int) -> Int {
        if mode == .pagedRTL {
            return max(0, pages.count - 1 - pageIndex)
        }
        return pageIndex
    }

    private func pageIndex(forVisualIndex visualIndex: Int) -> Int {
        if mode == .pagedRTL {
            return max(0, pages.count - 1 - visualIndex)
        }
        return visualIndex
    }

    private func preloadPages(around pageIndex: Int, includeCurrent: Bool) {
        let preloadCount = aidokuLegacyReaderPrefetchCount()
        guard preloadCount > 0 || includeCurrent else { return }
        var candidateIndexes = includeCurrent ? [pageIndex] : []
        if preloadCount > 0 {
            candidateIndexes += (1...preloadCount).flatMap { offset -> [Int] in
                return [pageIndex + offset, pageIndex - offset]
            }
        }
        for candidateIndex in candidateIndexes where pages.indices.contains(candidateIndex) {
            guard case .url(let url, let context) = pages[candidateIndex].content else { continue }
            LegacyReaderImagePipeline.shared.preload(url: url, context: context, source: source)
        }
    }

    private func readerMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("missing chapter data") {
            return "This chapter is unavailable from the source."
        }
        return message
    }

    @objc private func toggleBars() {
        barsHidden.toggle()
        navigationController?.setNavigationBarHidden(barsHidden, animated: true)
        overlayView.setControlsHidden(barsHidden, animated: true)
        enforceReaderContainer()
        UIView.animate(withDuration: 0.2, animations: {
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
        })
    }

    @objc private func handleReaderTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: view)
        if location.x < view.bounds.width * 0.33 {
            movePage(delta: -1)
        } else if location.x > view.bounds.width * 0.67 {
            movePage(delta: 1)
        } else {
            toggleBars()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return shouldHandleReaderTap(from: touch)
    }

    private func shouldHandleReaderTap(from touch: UITouch) -> Bool {
        var view = touch.view
        while let currentView = view {
            if let zoomableView = currentView as? LegacyZoomableImageView {
                return !zoomableView.isZoomed
            }
            view = currentView.superview
        }
        return true
    }

    private func movePage(delta: Int) {
        guard !pages.isEmpty else { return }
        let current = currentPageIndex ?? initialPageIndex
        let next = min(max(current + delta, 0), pages.count - 1)
        guard next != current else {
            overlayView.showGuide(modeTitle: mode.title)
            return
        }
        scrollTo(pageIndex: next, animated: true)
        currentPageIndex = next
        recordHistory(pageIndex: next, force: false)
        updatePageHUD()
    }

    private func jumpToPage(_ pageIndex: Int, animated: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        scrollTo(pageIndex: pageIndex, animated: animated)
        currentPageIndex = pageIndex
        preloadPages(around: pageIndex, includeCurrent: true)
        recordHistory(pageIndex: pageIndex, force: true)
        updatePageHUD()
    }

    private func installOverlayIfNeeded() {
        guard overlayView.superview == nil else { return }
        guard let hostView = navigationController?.view ?? view else { return }
        overlayView.onPageSelected = { [weak self] pageIndex in
            self?.jumpToPage(pageIndex, animated: false)
        }
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
        overlayView.setControlsHidden(barsHidden, animated: false)
        updatePageHUD()
    }

    private func showTapOverlayIfNeeded() {
        guard aidokuLegacyReaderShowsTapZones(), !didShowTapOverlay else { return }
        didShowTapOverlay = true
        overlayView.showGuide(modeTitle: mode.title)
    }

    private func updatePageHUD() {
        overlayView.updatePage(index: currentPageIndex, count: pages.count)
    }

    private func registerAppStateObservers() {
        let center = NotificationCenter.default
        appStateObservers.append(
            center.addObserver(forName: .legacyMemoryTrimRequested, object: nil, queue: .main) { [weak self] _ in
                self?.trimReaderMemory(keepCurrentPage: true)
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppWillEnterForeground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppWillEnterForeground()
            }
        )
    }

    private func handleAppDidEnterBackground() {
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        didTrimVisibleImagesForBackground = true
        trimReaderMemory(keepCurrentPage: false)
    }

    private func handleAppWillEnterForeground() {
        guard didTrimVisibleImagesForBackground else { return }
        didTrimVisibleImagesForBackground = false
        let pageIndex = currentPageIndex
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        guard let pageIndex = pageIndex, pages.indices.contains(pageIndex) else { return }
        DispatchQueue.main.async {
            self.scrollTo(pageIndex: pageIndex, animated: false)
            self.currentPageIndex = pageIndex
            self.updatePageHUD()
        }
    }

    private func trimReaderMemory(keepCurrentPage: Bool) {
        let current = keepCurrentPage ? currentPageIndex : nil
        for cell in collectionView.visibleCells {
            guard let pageCell = cell as? LegacyPagedImageCell else { continue }
            let indexPath = collectionView.indexPath(for: cell)
            let visiblePageIndex: Int?
            if let indexPath = indexPath {
                visiblePageIndex = pageIndex(forVisualIndex: indexPath.item)
            } else {
                visiblePageIndex = nil
            }
            if visiblePageIndex != current {
                pageCell.releaseDecodedImage()
            }
        }
        aidokuLegacyTrimVolatileCaches()
    }

    private func enforceReaderContainer(relayout: Bool = true) {
        tabBarController?.tabBar.isHidden = true
        guard relayout else { return }
        tabBarController?.view.setNeedsLayout()
        tabBarController?.view.layoutIfNeeded()
    }

    private func recordHistory(pageIndex: Int, force: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        let now = Date()
        if force {
            pendingHistorySaveWorkItem?.cancel()
            pendingHistorySaveWorkItem = nil
        } else {
            if lastSavedHistoryPageIndex == pageIndex {
                return
            }
            let saveDelay = 2 - now.timeIntervalSince(lastHistorySaveDate)
            if saveDelay > 0 {
                pendingHistorySaveWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard self?.currentPageIndex == pageIndex else { return }
                    self?.recordHistory(pageIndex: pageIndex, force: true)
                }
                pendingHistorySaveWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: workItem)
                return
            }
        }
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        LegacyHistoryStore.shared.update(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        LegacyReaderSessionStore.shared.save(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        lastSavedHistoryPageIndex = pageIndex
        lastHistorySaveDate = now
    }
}

private final class LegacyPagedMessageCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white
        label.textAlignment = .center
        label.numberOfLines = 0
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ message: String) {
        label.text = message
    }
}

private final class LegacyReaderOverlayView: UIView {
    private let leftZone = UILabel()
    private let rightZone = UILabel()
    private let modeLabel = UILabel()
    private let pageLabel = UILabel()
    private let sliderContainer = UIView()
    private let pageSlider = UISlider()
    private var hideWorkItem: DispatchWorkItem?
    private var pageCount = 0
    private var isUpdatingSlider = false
    private var controlsHidden = false
    var onPageSelected: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        configureZone(leftZone, text: "Prev", color: UIColor.orange.withAlphaComponent(0.55))
        configureZone(rightZone, text: "Next", color: UIColor.green.withAlphaComponent(0.50))
        configurePill(modeLabel, fontSize: 22)
        configurePill(pageLabel, fontSize: 15)
        configureSlider()
        pageLabel.alpha = 0.95

        addSubview(leftZone)
        addSubview(rightZone)
        addSubview(modeLabel)
        addSubview(sliderContainer)
        addSubview(pageLabel)

        NSLayoutConstraint.activate([
            leftZone.topAnchor.constraint(equalTo: topAnchor),
            leftZone.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftZone.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftZone.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.33),

            rightZone.topAnchor.constraint(equalTo: topAnchor),
            rightZone.leadingAnchor.constraint(equalTo: leftZone.trailingAnchor),
            rightZone.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightZone.bottomAnchor.constraint(equalTo: bottomAnchor),

            modeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeLabel.bottomAnchor.constraint(equalTo: pageLabel.topAnchor, constant: -84),
            modeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            modeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            pageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),

            sliderContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            sliderContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            sliderContainer.bottomAnchor.constraint(equalTo: pageLabel.topAnchor, constant: -10),
            sliderContainer.heightAnchor.constraint(equalToConstant: 38),

            pageSlider.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 14),
            pageSlider.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -14),
            pageSlider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor)
        ])
        hideGuide(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !controlsHidden else { return false }
        guard sliderContainer.alpha > 0.01, !sliderContainer.isHidden else { return false }
        let sliderFrame = sliderContainer.frame.insetBy(dx: -8, dy: -12)
        return sliderFrame.contains(point)
    }

    func setControlsHidden(_ hidden: Bool, animated: Bool) {
        controlsHidden = hidden
        if hidden {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        }
        let changes = {
            self.leftZone.alpha = 0
            self.rightZone.alpha = 0
            self.modeLabel.alpha = 0
            self.pageLabel.alpha = hidden || !aidokuLegacyReaderShowsPageNumber() || self.pageLabel.text == nil ? 0 : 0.95
            self.sliderContainer.alpha = hidden || self.pageCount <= 1 ? 0 : 0.92
        }
        if animated {
            UIView.animate(withDuration: 0.18, animations: changes)
        } else {
            changes()
        }
    }

    func updatePage(index: Int?, count: Int) {
        pageCount = count
        updateSlider(index: index, count: count)
        guard count > 0, let index = index else {
            pageLabel.text = nil
            pageLabel.alpha = 0
            return
        }
        pageLabel.text = "\(min(max(index + 1, 1), count)) / \(count)"
        pageLabel.alpha = !controlsHidden && aidokuLegacyReaderShowsPageNumber() ? 0.95 : 0
    }

    func showGuide(modeTitle: String) {
        hideWorkItem?.cancel()
        guard !controlsHidden else {
            setControlsHidden(true, animated: false)
            return
        }
        guard aidokuLegacyReaderShowsTapZones() else {
            leftZone.alpha = 0
            rightZone.alpha = 0
            modeLabel.alpha = 0
            pageLabel.alpha = !controlsHidden && aidokuLegacyReaderShowsPageNumber() && pageLabel.text != nil ? 0.95 : 0
            return
        }
        modeLabel.text = modeTitle
        UIView.animate(withDuration: 0.18) {
            self.leftZone.alpha = 1
            self.rightZone.alpha = 1
            self.modeLabel.alpha = 1
            self.pageLabel.alpha = !self.controlsHidden && aidokuLegacyReaderShowsPageNumber() && self.pageLabel.text != nil ? 0.95 : 0
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideGuide(animated: true)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func hideGuide(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let changes = {
            self.leftZone.alpha = 0
            self.rightZone.alpha = 0
            self.modeLabel.alpha = 0
            self.pageLabel.alpha = !self.controlsHidden && aidokuLegacyReaderShowsPageNumber() && self.pageLabel.text != nil ? 0.95 : 0
            self.sliderContainer.alpha = !self.controlsHidden && self.pageCount > 1 ? 0.92 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: changes)
        } else {
            changes()
        }
    }

    private func configureZone(_ label: UILabel, text: String, color: UIColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = color
        label.text = text
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 28)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    private func configurePill(_ label: UILabel, fontSize: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: fontSize)
        label.layer.cornerRadius = 18
        label.layer.masksToBounds = true
        label.numberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.layoutMargins = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
    }

    private func configureSlider() {
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        sliderContainer.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        sliderContainer.layer.cornerRadius = 10
        sliderContainer.layer.masksToBounds = true
        sliderContainer.alpha = 0

        pageSlider.translatesAutoresizingMaskIntoConstraints = false
        pageSlider.minimumValue = 0
        pageSlider.maximumValue = 0
        pageSlider.isContinuous = false
        pageSlider.minimumTrackTintColor = LegacyPalette.accent
        pageSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.30)
        pageSlider.thumbTintColor = UIColor.white
        pageSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        sliderContainer.addSubview(pageSlider)
    }

    private func updateSlider(index: Int?, count: Int) {
        isUpdatingSlider = true
        pageSlider.minimumValue = 0
        pageSlider.maximumValue = Float(max(count - 1, 0))
        if let index = index {
            pageSlider.value = Float(min(max(index, 0), max(count - 1, 0)))
        } else {
            pageSlider.value = 0
        }
        pageSlider.isEnabled = count > 1
        sliderContainer.alpha = !controlsHidden && count > 1 ? 0.92 : 0
        isUpdatingSlider = false
    }

    @objc private func sliderValueChanged() {
        guard !isUpdatingSlider, pageCount > 1 else { return }
        let pageIndex = min(max(Int(round(pageSlider.value)), 0), pageCount - 1)
        pageSlider.setValue(Float(pageIndex), animated: false)
        pageLabel.text = "\(pageIndex + 1) / \(pageCount)"
        pageLabel.alpha = !controlsHidden && aidokuLegacyReaderShowsPageNumber() ? 0.95 : 0
        onPageSelected?(pageIndex)
    }
}

private final class LegacyZoomableImageView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()

    var isZoomed: Bool {
        return zoomScale > minimumZoomScale + 0.01
    }

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.contentScaleFactor = UIScreen.main.scale
            imageView.layer.contentsScale = UIScreen.main.scale
            setZoomScale(1, animated: false)
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = aidokuLegacyIsLowMemoryMode() ? 2 : 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        canCancelContentTouches = true
        panGestureRecognizer.delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.contentScaleFactor = UIScreen.main.scale
        imageView.layer.contentsScale = UIScreen.main.scale
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImageIfNeeded()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGestureRecognizer {
            return zoomScale > minimumZoomScale
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private func centerImageIfNeeded() {
        let boundsSize = bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) / 2 : 0
        frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) / 2 : 0
        imageView.frame = frame
    }
}

private final class LegacyPageImageCell: UITableViewCell {
    private let pageImageView = LegacyZoomableImageView()
    private let pageLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint!
    private var task: URLSessionDataTask?
    private var representedLoadID = UUID()
    private var availableSize = CGSize(width: UIScreen.main.bounds.width, height: 420)
    private var fitsViewport = false
    var onHeightChange: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor.black
        selectionStyle = .none
        pageImageView.translatesAutoresizingMaskIntoConstraints = false
        pageImageView.contentMode = .scaleAspectFit
        pageImageView.backgroundColor = UIColor.black
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textColor = UIColor.white
        pageLabel.textAlignment = .center
        pageLabel.numberOfLines = 0
        contentView.addSubview(pageImageView)
        contentView.addSubview(pageLabel)
        heightConstraint = pageImageView.heightAnchor.constraint(equalToConstant: 420)
        NSLayoutConstraint.activate([
            pageImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            heightConstraint,
            pageImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            pageLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            pageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            pageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            pageLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseDecodedImage()
        pageLabel.text = nil
        pageImageView.isHidden = false
        availableSize = CGSize(width: UIScreen.main.bounds.width, height: 420)
        fitsViewport = false
        heightConstraint.constant = 420
        onHeightChange = nil
    }

    var currentLoadID: UUID {
        return representedLoadID
    }

    func releaseDecodedImage() {
        task?.cancel()
        task = nil
        representedLoadID = UUID()
        pageImageView.image = nil
    }

    func releaseDecodedImage(ifLoadID loadID: UUID) {
        guard representedLoadID == loadID else { return }
        releaseDecodedImage()
    }

    func configure(
        page: AidokuRunnerLegacyPage,
        source: AidokuRunnerLegacySource,
        availableSize: CGSize,
        fitsViewport: Bool
    ) {
        let loadID = UUID()
        representedLoadID = loadID
        self.availableSize = availableSize
        self.fitsViewport = fitsViewport
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageImageView.isHidden = false
        pageLabel.text = nil
        heightConstraint.constant = fitsViewport ? max(320, availableSize.height) : 420
        switch page.content {
            case .url(let url, let context):
                pageLabel.text = "Loading..."
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source) { [weak self] image in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    if let image = image {
                        self.setImage(image, loadID: loadID)
                    } else {
                        self.showFailure("Image failed to load.", loadID: loadID)
                    }
                }
            case .image(let data):
                setImage(from: data, loadID: loadID)
            case .text(let text):
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = text
            case .zipFile(_, _):
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = "ZIP pages are not supported in the legacy reader yet."
        }
    }

    private func loadLocalImage(url: URL, loadID: UUID) {
        pageLabel.text = "Loading..."
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                return LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure("Downloaded image failed to decode.", loadID: loadID)
                }
            }
        }
    }

    private func load(
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        retriesRemaining: Int = 1
    ) {
        task?.cancel()
        task = aidokuLegacyReaderImageSession.dataTask(with: request) { [weak self] data, response, error in
            if source.runner.features.processesPages {
                DispatchQueue.main.async {
                    self?.handleLoadResult(
                        data: data,
                        response: response,
                        error: error,
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        retriesRemaining: retriesRemaining
                    )
                }
                return
            }
            self?.handleDirectLoadResult(
                data: data,
                response: response,
                error: error,
                request: request,
                context: context,
                source: source,
                loadID: loadID,
                retriesRemaining: retriesRemaining
            )
        }
        task?.resume()
    }

    private func handleDirectLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        retriesRemaining: Int
    ) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.async {
                guard self.representedLoadID == loadID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    self.load(
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        retriesRemaining: retriesRemaining - 1
                    )
                }
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage(data: data, response: httpResponse))
    }

    private func handleLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        retriesRemaining: Int
    ) {
        guard representedLoadID == loadID else { return }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.representedLoadID == loadID else { return }
                self.load(
                    request: request,
                    context: context,
                    source: source,
                    loadID: loadID,
                    retriesRemaining: retriesRemaining - 1
                )
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        let decodeFailureMessage = self.decodeFailureMessage(data: data, response: httpResponse)
        guard source.runner.features.processesPages, let httpResponse = httpResponse else {
            setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
            return
        }
        source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                switch result {
                    case .success(let image?):
                        self.setProcessedImage(image, loadID: loadID)
                    case .success(nil):
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                    case .failure:
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                }
            }
        }
    }

    private func shouldRetry(error: Error?, statusCode: Int?, data: Data?) -> Bool {
        if error != nil || data == nil || data?.isEmpty == true {
            return true
        }
        guard let statusCode = statusCode else { return false }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func showFailure(_ message: String, loadID: UUID) {
        DispatchQueue.main.async {
            guard self.representedLoadID == loadID else { return }
            self.pageImageView.isHidden = true
            self.heightConstraint.constant = 180
            self.pageLabel.text = message
            self.onHeightChange?()
        }
    }

    private func setProcessedImage(_ image: UIImage, loadID: UUID) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let preparedImage = autoreleasepool {
                aidokuLegacyPrepareReaderImageForDisplay(
                    LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                )
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                self.setImage(preparedImage, loadID: loadID)
            }
        }
    }

    private func setImage(
        from data: Data,
        loadID: UUID,
        failureMessage: String = "Image failed to load."
    ) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool {
                LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure(failureMessage, loadID: loadID)
                }
            }
        }
    }

    private func setImage(_ image: UIImage, loadID: UUID) {
        guard representedLoadID == loadID else { return }
        pageLabel.text = nil
        pageImageView.isHidden = false
        pageImageView.image = image
        if fitsViewport {
            heightConstraint.constant = max(320, availableSize.height)
        } else {
            let width = max(availableSize.width, 1)
            let ratio = image.size.height / max(image.size.width, 1)
            let maximumHeight: CGFloat = aidokuLegacyIsLowMemoryMode() ? max(availableSize.height, 768) : 2600
            let targetHeight = min(max(width * ratio, 320), maximumHeight)
            heightConstraint.constant = targetHeight
        }
        onHeightChange?()
    }

    private func loadFailureMessage(error: Error?, response: HTTPURLResponse?) -> String {
        if let statusCode = response?.statusCode, !(200..<300).contains(statusCode) {
            return httpFailureMessage(statusCode: statusCode, response: response)
        }
        if let error = error {
            return "Image failed to load: \(error.localizedDescription)"
        }
        return "Image failed to load."
    }

    private func httpFailureMessage(statusCode: Int, response: HTTPURLResponse?) -> String {
        if let contentType = headerValue("Content-Type", in: response), !contentType.isEmpty {
            return "Image failed to load. HTTP \(statusCode). \(contentType)"
        }
        return "Image failed to load. HTTP \(statusCode)."
    }

    private func decodeFailureMessage(data: Data, response: HTTPURLResponse?) -> String {
        let contentType = headerValue("Content-Type", in: response)?.lowercased() ?? ""
        if contentType.contains("webp") {
            return "WebP image failed to decode."
        }
        if contentType.contains("avif") {
            return "AVIF image failed to decode."
        }
        if contentType.contains("html") || looksLikeHTML(data) {
            return "Image request returned HTML instead of an image."
        }
        if !contentType.isEmpty && !contentType.contains("image") {
            return "Image request returned \(contentType)."
        }
        return "Image failed to decode."
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse?) -> String? {
        return response?.allHeaderFields.first { header in
            guard let key = header.key as? String else { return false }
            return key.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = Data(data.prefix(128))
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<html") || text.contains("<!doctype")
    }
}

private final class LegacyPagedImageCell: UICollectionViewCell {
    private let pageImageView = LegacyZoomableImageView()
    private let pageLabel = UILabel()
    private var task: URLSessionDataTask?
    private var representedLoadID = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black
        contentView.backgroundColor = UIColor.black
        pageImageView.translatesAutoresizingMaskIntoConstraints = false
        pageImageView.contentMode = .scaleAspectFit
        pageImageView.backgroundColor = UIColor.black
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textColor = UIColor.white
        pageLabel.textAlignment = .center
        pageLabel.numberOfLines = 0
        contentView.addSubview(pageImageView)
        contentView.addSubview(pageLabel)
        NSLayoutConstraint.activate([
            pageImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            pageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            pageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            pageLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseDecodedImage()
        pageLabel.text = nil
        pageImageView.isHidden = false
    }

    var currentLoadID: UUID {
        return representedLoadID
    }

    func releaseDecodedImage() {
        task?.cancel()
        task = nil
        representedLoadID = UUID()
        pageImageView.image = nil
    }

    func releaseDecodedImage(ifLoadID loadID: UUID) {
        guard representedLoadID == loadID else { return }
        releaseDecodedImage()
    }

    func configure(page: AidokuRunnerLegacyPage, source: AidokuRunnerLegacySource) {
        let loadID = UUID()
        representedLoadID = loadID
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageImageView.isHidden = false
        pageLabel.text = nil
        switch page.content {
            case .url(let url, let context):
                pageLabel.text = "Loading..."
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source) { [weak self] image in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    if let image = image {
                        self.setImage(image, loadID: loadID)
                    } else {
                        self.showFailure("Image failed to load.", loadID: loadID)
                    }
                }
            case .image(let data):
                setImage(from: data, loadID: loadID)
            case .text(let text):
                pageImageView.isHidden = true
                pageLabel.text = text
            case .zipFile(_, _):
                pageImageView.isHidden = true
                pageLabel.text = "ZIP pages are not supported in the legacy reader yet."
        }
    }

    private func loadLocalImage(url: URL, loadID: UUID) {
        pageLabel.text = "Loading..."
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                return LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure("Downloaded image failed to decode.", loadID: loadID)
                }
            }
        }
    }

    private func load(
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        retriesRemaining: Int = 1
    ) {
        task?.cancel()
        task = aidokuLegacyReaderImageSession.dataTask(with: request) { [weak self] data, response, error in
            if source.runner.features.processesPages {
                DispatchQueue.main.async {
                    self?.handleLoadResult(
                        data: data,
                        response: response,
                        error: error,
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        retriesRemaining: retriesRemaining
                    )
                }
                return
            }
            self?.handleDirectLoadResult(
                data: data,
                response: response,
                error: error,
                request: request,
                context: context,
                source: source,
                loadID: loadID,
                retriesRemaining: retriesRemaining
            )
        }
        task?.resume()
    }

    private func handleDirectLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        retriesRemaining: Int
    ) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.async {
                guard self.representedLoadID == loadID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    self.load(
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        retriesRemaining: retriesRemaining - 1
                    )
                }
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage(data: data, response: httpResponse))
    }

    private func handleLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        retriesRemaining: Int
    ) {
        guard representedLoadID == loadID else { return }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.representedLoadID == loadID else { return }
                self.load(
                    request: request,
                    context: context,
                    source: source,
                    loadID: loadID,
                    retriesRemaining: retriesRemaining - 1
                )
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        let decodeFailureMessage = self.decodeFailureMessage(data: data, response: httpResponse)
        guard source.runner.features.processesPages, let httpResponse = httpResponse else {
            setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
            return
        }
        source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                switch result {
                    case .success(let image?):
                        self.setProcessedImage(image, loadID: loadID)
                    case .success(nil):
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                    case .failure:
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                }
            }
        }
    }

    private func shouldRetry(error: Error?, statusCode: Int?, data: Data?) -> Bool {
        if error != nil || data == nil || data?.isEmpty == true {
            return true
        }
        guard let statusCode = statusCode else { return false }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func showFailure(_ message: String, loadID: UUID) {
        DispatchQueue.main.async {
            guard self.representedLoadID == loadID else { return }
            self.pageImageView.isHidden = true
            self.pageLabel.text = message
        }
    }

    private func setProcessedImage(_ image: UIImage, loadID: UUID) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let preparedImage = autoreleasepool {
                aidokuLegacyPrepareReaderImageForDisplay(
                    LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                )
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                self.setImage(preparedImage, loadID: loadID)
            }
        }
    }

    private func setImage(
        from data: Data,
        loadID: UUID,
        failureMessage: String = "Image failed to load."
    ) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool {
                LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure(failureMessage, loadID: loadID)
                }
            }
        }
    }

    private func setImage(_ image: UIImage, loadID: UUID) {
        guard representedLoadID == loadID else { return }
        pageLabel.text = nil
        pageImageView.isHidden = false
        pageImageView.image = image
    }

    private func loadFailureMessage(error: Error?, response: HTTPURLResponse?) -> String {
        if let statusCode = response?.statusCode, !(200..<300).contains(statusCode) {
            return httpFailureMessage(statusCode: statusCode, response: response)
        }
        if let error = error {
            return "Image failed to load: \(error.localizedDescription)"
        }
        return "Image failed to load."
    }

    private func httpFailureMessage(statusCode: Int, response: HTTPURLResponse?) -> String {
        if let contentType = headerValue("Content-Type", in: response), !contentType.isEmpty {
            return "Image failed to load. HTTP \(statusCode). \(contentType)"
        }
        return "Image failed to load. HTTP \(statusCode)."
    }

    private func decodeFailureMessage(data: Data, response: HTTPURLResponse?) -> String {
        let contentType = headerValue("Content-Type", in: response)?.lowercased() ?? ""
        if contentType.contains("webp") {
            return "WebP image failed to decode."
        }
        if contentType.contains("avif") {
            return "AVIF image failed to decode."
        }
        if contentType.contains("html") || looksLikeHTML(data) {
            return "Image request returned HTML instead of an image."
        }
        if !contentType.isEmpty && !contentType.contains("image") {
            return "Image request returned \(contentType)."
        }
        return "Image failed to decode."
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse?) -> String? {
        return response?.allHeaderFields.first { header in
            guard let key = header.key as? String else { return false }
            return key.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = Data(data.prefix(128))
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<html") || text.contains("<!doctype")
    }
}

private extension AidokuRunnerLegacyChapter {
    var normalizedLanguage: String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return nil
        }
        return language.lowercased()
    }

    var legacyFormattedTitle: String {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefix: [String] = []
        if let volumeNumber = volumeNumber {
            prefix.append("Vol. \(Self.format(number: volumeNumber))")
        }
        if let chapterNumber = chapterNumber {
            prefix.append("Ch. \(Self.format(number: chapterNumber))")
        }
        if prefix.isEmpty {
            if let cleanTitle = cleanTitle, !cleanTitle.isEmpty {
                return cleanTitle
            }
            return "Chapter \(key)"
        }
        if let cleanTitle = cleanTitle, !cleanTitle.isEmpty {
            return "\(prefix.joined(separator: " ")) - \(cleanTitle)"
        }
        return prefix.joined(separator: " ")
    }

    func legacyFormattedSubtitle(sourceKey: String) -> String? {
        var components: [String] = []
        if locked {
            components.append("Unavailable")
        }
        if let dateUploaded = dateUploaded {
            components.append(LegacyChapterFormatters.dateFormatter.string(from: dateUploaded))
        }
        if let scanlators = scanlators, !scanlators.isEmpty {
            components.append(scanlators.joined(separator: ", "))
        }
        if
            let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
            !language.isEmpty,
            shouldShowLanguage(sourceKey: sourceKey)
        {
            components.append(language.uppercased())
        }
        return components.isEmpty ? nil : components.joined(separator: " - ")
    }

    private func shouldShowLanguage(sourceKey: String) -> Bool {
        let selectedLanguages = UserDefaults.standard.stringArray(forKey: "\(sourceKey).languages") ?? []
        return selectedLanguages.count > 1
    }

    private static func format(number: Float) -> String {
        return LegacyChapterFormatters.numberFormatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}

private enum LegacyChapterFormatters {
    static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private extension AidokuRunnerLegacyManga {
    func coverURL(relativeTo baseURL: URL?) -> URL? {
        return coverURLCandidates(relativeTo: baseURL).first
    }

    func coverURLCandidates(relativeTo baseURL: URL?) -> [URL] {
        guard let cover = cover?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty else {
            return []
        }
        var urls: [URL] = []
        for candidate in Self.urlCandidates(from: cover) {
            if let url = URL(string: candidate), url.scheme != nil {
                Self.appendURL(url, to: &urls)
            }
        }
        if let baseURL = baseURL {
            for candidate in Self.urlCandidates(from: cover) {
                if let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL {
                    Self.appendURL(url, to: &urls)
                }
            }
        }
        for candidate in Self.urlCandidates(from: cover) {
            if let url = URL(string: candidate) {
                Self.appendURL(url, to: &urls)
            }
        }
        let initialURLs = urls
        for url in initialURLs {
            for fallbackURL in legacyMangaDexCoverFallbackURLs(from: url) {
                Self.appendURL(fallbackURL, to: &urls)
            }
        }
        for url in Self.inferredMangaDexCoverURLs(from: cover, baseURL: baseURL, mangaKey: key) {
            Self.appendURL(url, to: &urls)
        }
        return urls
    }

    private static func urlCandidates(from value: String) -> [String] {
        var candidates: [String] = []
        let normalized = value.replacingOccurrences(of: "\\/", with: "/")
        appendURLCandidate(normalized, to: &candidates)
        appendURLCandidate(normalized.replacingOccurrences(of: " ", with: "%20"), to: &candidates)
        if let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            appendURLCandidate(encoded, to: &candidates)
        }
        return candidates
    }

    private static func appendURLCandidate(_ value: String, to candidates: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendUnique(trimmed, to: &candidates)
        if trimmed.hasPrefix("//") {
            appendUnique("https:" + trimmed, to: &candidates)
        } else if looksLikeHostPath(trimmed) {
            appendUnique("https://" + trimmed, to: &candidates)
        }
    }

    private static func looksLikeHostPath(_ value: String) -> Bool {
        guard !value.contains("://"), !value.hasPrefix("/"), !value.contains(" ") else {
            return false
        }
        let host = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        return host.contains(".")
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private static func appendURL(_ url: URL, to urls: inout [URL]) {
        guard !urls.contains(url) else { return }
        urls.append(url)
    }

    private static func inferredMangaDexCoverURLs(from cover: String, baseURL: URL?, mangaKey: String) -> [URL] {
        guard looksLikeMangaDex(baseURL: baseURL, mangaKey: mangaKey) else { return [] }
        let normalized = cover.replacingOccurrences(of: "\\/", with: "/")
        let fileName = (normalized as NSString).lastPathComponent
        guard fileName.contains(".") else { return [] }

        var urls: [URL] = []
        for fileName in legacyMangaDexCoverFileNameCandidates(from: fileName) {
            guard let url = URL(string: "https://uploads.mangadex.org/covers/\(mangaKey)/\(fileName)") else { continue }
            appendURL(url, to: &urls)
        }
        return urls
    }

    private static func looksLikeMangaDex(baseURL: URL?, mangaKey: String) -> Bool {
        if baseURL?.host?.lowercased().contains("mangadex") == true {
            return true
        }
        return mangaKey.range(
            of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}

private struct LegacyWebLoginResult {
    let cookies: [String: String]
    let localStorage: [String: String]
}

private final class LegacySourceWebViewController: UIViewController, WKNavigationDelegate {
    private let initialURL: URL
    private let sourceTitle: String
    private let localStorageKeys: [String]
    private let loginCompletion: ((LegacyWebLoginResult) -> Void)?
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)

    init(
        url: URL,
        title: String,
        localStorageKeys: [String] = [],
        loginCompletion: ((LegacyWebLoginResult) -> Void)? = nil
    ) {
        self.initialURL = url
        self.sourceTitle = title
        self.localStorageKeys = localStorageKeys
        self.loginCompletion = loginCompletion
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var rightItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(openInSafari)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadPage))
        ]
        if loginCompletion != nil {
            rightItems.insert(UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(finishLogin)), at: 0)
        }
        navigationItem.rightBarButtonItems = rightItems
        progressView.frame = CGRect(x: 0, y: 0, width: 120, height: 2)
        updateToolbar(animated: false)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        webView.load(URLRequest(url: initialURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == #keyPath(WKWebView.estimatedProgress) else { return }
        progressView.progress = Float(webView.estimatedProgress)
        progressView.isHidden = webView.estimatedProgress >= 1
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        progressView.isHidden = false
        updateTitle()
        updateToolbar(animated: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressView.isHidden = true
        updateTitle()
        updateToolbar(animated: true)
    }

    private func updateToolbar(animated: Bool) {
        let back = UIBarButtonItem(title: "Back", style: .plain, target: self, action: #selector(goBack))
        back.isEnabled = webView?.canGoBack ?? false

        let forward = UIBarButtonItem(title: "Forward", style: .plain, target: self, action: #selector(goForward))
        forward.isEnabled = webView?.canGoForward ?? false

        setToolbarItems(
            [
                back,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(customView: progressView),
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                forward
            ],
            animated: animated
        )
    }

    private func updateTitle() {
        title = webView.title?.isEmpty == false ? webView.title : sourceTitle
    }

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openInSafari() {
        guard let url = webView.url ?? URL(string: initialURL.absoluteString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @objc private func finishLogin() {
        collectLocalStorage { [weak self] localStorage in
            guard let self = self else { return }
            self.collectCookies { cookies in
                self.loginCompletion?(LegacyWebLoginResult(cookies: cookies, localStorage: localStorage))
            }
        }
    }

    private func collectLocalStorage(completion: @escaping ([String: String]) -> Void) {
        guard !localStorageKeys.isEmpty else {
            completion([:])
            return
        }
        guard
            let keysData = try? JSONSerialization.data(withJSONObject: localStorageKeys, options: []),
            let keysJSON = String(data: keysData, encoding: .utf8)
        else {
            completion([:])
            return
        }
        let script = """
        (function() {
          var result = {};
          \(keysJSON).forEach(function(key) {
            var value = window.localStorage.getItem(key);
            if (value !== null) { result[key] = value; }
          });
          return result;
        })();
        """
        webView.evaluateJavaScript(script) { value, _ in
            let dictionary = value as? [String: Any] ?? [:]
            let strings = dictionary.reduce(into: [String: String]()) { result, item in
                if let value = item.value as? String {
                    result[item.key] = value
                }
            }
            completion(strings)
        }
    }

    private func collectCookies(completion: @escaping ([String: String]) -> Void) {
        var cookies = cookieValues(from: HTTPCookieStorage.shared.cookies ?? [])
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] webCookies in
            guard let self = self else { return }
            for cookie in webCookies where self.isRelevant(cookie: cookie) {
                HTTPCookieStorage.shared.setCookie(cookie)
                cookies[cookie.name] = cookie.value
            }
            DispatchQueue.main.async {
                completion(cookies)
            }
        }
    }

    private func cookieValues(from cookies: [HTTPCookie]) -> [String: String] {
        return cookies.reduce(into: [String: String]()) { result, cookie in
            guard isRelevant(cookie: cookie) else { return }
            result[cookie.name] = cookie.value
        }
    }

    private func isRelevant(cookie: HTTPCookie) -> Bool {
        guard let host = initialURL.host?.lowercased(), !host.isEmpty else { return true }
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain == host || domain.hasSuffix(".\(host)") || host.hasSuffix(".\(domain)")
    }
}
