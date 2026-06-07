//
//  LegacyRootViewController.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit
import WebKit
import ImageIO

enum LegacyPalette {
    static let background = UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
    static let panel = UIColor.white
    static let primaryText = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    static let secondaryText = UIColor(red: 0.34, green: 0.35, blue: 0.38, alpha: 1)
    static let accent = UIColor(red: 0.83, green: 0.12, blue: 0.36, alpha: 1)
}

private extension Notification.Name {
    static let legacyInstalledSourcesDidChange = Notification.Name("AidokuLegacyInstalledSourcesDidChange")
    static let legacyLibraryDidChange = Notification.Name("AidokuLegacyLibraryDidChange")
    static let legacyHistoryDidChange = Notification.Name("AidokuLegacyHistoryDidChange")
}

final class LegacyTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.tintColor = LegacyPalette.accent

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
    }
}

struct LegacyLibraryEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var dateAdded: Date

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
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyLibraryEntry].self, from: data)
        else {
            return []
        }
        return entries.sorted { $0.dateAdded > $1.dateAdded }
    }

    func contains(sourceKey: String, mangaKey: String) -> Bool {
        return entries.contains { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    func add(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = entries.filter { !($0.sourceKey == source.key && $0.manga.key == manga.key) }
        current.insert(
            LegacyLibraryEntry(sourceKey: source.key, sourceName: source.name, manga: manga, dateAdded: Date()),
            at: 0
        )
        save(current)
    }

    func remove(sourceKey: String, mangaKey: String) {
        save(entries.filter { !($0.sourceKey == sourceKey && $0.manga.key == mangaKey) })
    }

    func clear() {
        save([])
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
        var current = entries.filter { $0.key != key }
        current.insert(
            LegacyHistoryEntry(
                sourceKey: source.key,
                sourceName: source.name,
                manga: manga,
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

    func clear() {
        save([])
    }

    private func save(_ entries: [LegacyHistoryEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyHistoryDidChange, object: nil)
        }
    }
}

final class LegacyImageLoader {
    static let shared = LegacyImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 25
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        session = URLSession(configuration: configuration)
        cache.countLimit = 160
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func clear() {
        cache.removeAllObjects()
    }

    @discardableResult
    func load(
        url: URL,
        targetHeight: CGFloat = 220,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return nil
        }

        let task = session.dataTask(with: URLRequest(url: url)) { [weak self] data, _, _ in
            let image = data.flatMap { self?.makeImage(from: $0, maxPixelHeight: targetHeight * UIScreen.main.scale) }
            if let image = image {
                self?.cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale))
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
        task.resume()
        return task
    }

    func makeImage(from data: Data, maxPixelHeight: CGFloat) -> UIImage? {
        guard UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
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
    private var entries: [LegacyLibraryEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadData), for: .valueChanged)
        observer = NotificationCenter.default.addObserver(
            forName: .legacyLibraryDidChange,
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
        entries = LegacyLibraryStore.shared.entries
        sources = packageInstaller.loadInstalledSources()
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

        guard !entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "No manga in Library."
            cell.detailTextLabel?.text = "Open Sources, browse manga, then tap Add."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let entry = entries[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder()
        if let source = source(for: entry), let coverURL = entry.manga.coverURL(relativeTo: source.urls.first) {
            LegacyImageLoader.shared.load(url: coverURL, targetHeight: 130) { image in
                guard
                    let visibleIndexPath = tableView.indexPath(for: cell),
                    visibleIndexPath == indexPath
                else { return }
                cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
                cell.setNeedsLayout()
            }
        }
        cell.textLabel?.text = entry.manga.title
        cell.detailTextLabel?.text = entry.sourceName
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

    private func source(for entry: LegacyLibraryEntry) -> AidokuRunnerLegacySource? {
        return sources.first { $0.key == entry.sourceKey }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyHistoryViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var entries: [LegacyHistoryEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?

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
        cell.imageView?.image = LegacyImageLoader.placeholder()
        if let source = source(for: entry), let coverURL = entry.manga.coverURL(relativeTo: source.urls.first) {
            LegacyImageLoader.shared.load(url: coverURL, targetHeight: 130) { image in
                guard
                    let visibleIndexPath = tableView.indexPath(for: cell),
                    visibleIndexPath == indexPath
                else { return }
                cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
                cell.setNeedsLayout()
            }
        }
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
            LegacyReaderViewController(
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

    private func source(for entry: LegacyHistoryEntry) -> AidokuRunnerLegacySource? {
        return sources.first { $0.key == entry.sourceKey }
    }

    private func historySubtitle(for entry: LegacyHistoryEntry) -> String {
        let chapterTitle = entry.chapter.title
            ?? entry.chapter.chapterNumber.map { "Chapter \($0)" }
            ?? entry.chapter.key
        if entry.pageCount > 0 {
            return "\(chapterTitle) - Page \(entry.pageIndex + 1) of \(entry.pageCount)\n\(entry.sourceName)"
        }
        return "\(chapterTitle)\n\(entry.sourceName)"
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacySettingsViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case readerMemory
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
            case .readerMemory:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages")
                cell.textLabel?.text = "Reader Memory Mode"
                cell.detailTextLabel?.text = enabled ? "Optimized for iPad Air Gen 1" : "Full-size image decoding"
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
            case .readerMemory:
                let key = "AidokuLegacy.reader.downsampleImages"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
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
}

final class LegacyRootViewController: UITableViewController {
    private let catalogClient = LegacySourceCatalogClient()
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

        reloadInstalledSources()
        reloadCatalog()
    }

    @objc private func reloadCatalog() {
        loadingText = "Loading Aidoku Community Sources..."
        tableView.reloadData()

        catalogClient.fetchCatalog { [weak self] result in
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
        cell.imageView?.image = source.imageUrl.flatMap { UIImage(contentsOfFile: $0.path) } ?? LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
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
}

final class LegacySourceMenuViewController: UITableViewController {
    private enum Row {
        case home
        case search
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
                    let prefixCount = self.source.runner.features.providesHome ? 2 : 1
                    let insertIndex = min(prefixCount + self.source.staticListings.count, self.rows.count)
                    self.rows.insert(contentsOf: dynamicRows, at: insertIndex)
                case .failure(let error):
                    let prefixCount = self.source.runner.features.providesHome ? 2 : 1
                    self.rows.insert(
                        .message(title: "Listings Unavailable", subtitle: error.localizedDescription),
                        at: min(prefixCount + self.source.staticListings.count, self.rows.count)
                    )
            }
            self.tableView.reloadData()
        }
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
                navigationController?.pushViewController(
                    LegacyReaderViewController(source: source, manga: entry.manga, chapter: entry.chapter),
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
        if let title = chapter.title, !title.isEmpty {
            return title
        }
        if let number = chapter.chapterNumber {
            return "Chapter \(number)"
        }
        return chapter.scanlators?.joined(separator: ", ")
    }

    private func loadImage(for link: AidokuRunnerLegacyHomeLink, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let url = imageURL(for: link) else { return }
        LegacyImageLoader.shared.load(url: url, targetHeight: 130) { image in
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
        guard let url = manga.coverURL(relativeTo: source.urls.first) else { return }
        LegacyImageLoader.shared.load(url: url, targetHeight: 130) { image in
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
        if let coverURL = manga.coverURL(relativeTo: source.urls.first) {
            LegacyImageLoader.shared.load(url: coverURL, targetHeight: 130) { image in
                guard
                    let visibleIndexPath = tableView.indexPath(for: cell),
                    visibleIndexPath == indexPath
                else { return }
                cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
                cell.setNeedsLayout()
            }
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

final class LegacyMangaDetailViewController: UITableViewController {
    private let source: AidokuRunnerLegacySource
    private var manga: AidokuRunnerLegacyManga
    private var isLoading = false
    private var errorMessage: String?

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
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Add", style: .plain, target: self, action: #selector(toggleBookmark))
        ]
        updateBookmarkButton()
        loadDetails()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "Details" : "Chapters"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        let count = manga.chapters?.count ?? 0
        return count == 0 ? 1 : count
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
            if let coverURL = manga.coverURL(relativeTo: source.urls.first) {
                LegacyImageLoader.shared.load(url: coverURL, targetHeight: 180) { image in
                    guard
                        let visibleIndexPath = tableView.indexPath(for: cell),
                        visibleIndexPath == indexPath
                    else { return }
                    cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
                    cell.setNeedsLayout()
                }
            }
            cell.textLabel?.text = manga.title
            cell.detailTextLabel?.text = errorMessage ?? manga.description ?? manga.authors?.joined(separator: ", ") ?? "No description."
            cell.accessoryType = .none
            return cell
        }

        guard let chapters = manga.chapters, !chapters.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading chapters..." : "No chapters."
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            return cell
        }

        let chapter = chapters[indexPath.row]
        cell.imageView?.image = nil
        cell.textLabel?.text = chapter.title ?? "Chapter \(chapter.chapterNumber.map { String($0) } ?? chapter.key)"
        cell.detailTextLabel?.text = chapter.scanlators?.joined(separator: ", ")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard
            indexPath.section == 1,
            let chapters = manga.chapters,
            chapters.indices.contains(indexPath.row)
        else {
            return
        }
        let chapter = chapters[indexPath.row]
        navigationController?.pushViewController(
            LegacyReaderViewController(source: source, manga: manga, chapter: chapter),
            animated: true
        )
    }

    private func loadDetails() {
        isLoading = true
        tableView.reloadData()
        source.runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true) { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
                case .success(let updatedManga):
                    self.manga = updatedManga
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
            }
            self.updateBookmarkButton()
            self.tableView.reloadData()
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
        navigationItem.rightBarButtonItems?.first?.title = inLibrary ? "Remove" : "Add"
    }
}

final class LegacyReaderViewController: UITableViewController {
    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let chapter: AidokuRunnerLegacyChapter
    private let initialPageIndex: Int
    private var pages: [AidokuRunnerLegacyPage] = []
    private var message = "Loading pages..."
    private var didScrollToInitialPage = false

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
        title = chapter.title ?? manga.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = UIColor.black
        tableView.separatorStyle = .none
        tableView.register(LegacyPageImageCell.self, forCellReuseIdentifier: "PageImageCell")
        loadPages()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pages.isEmpty ? 1 : pages.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return pages.isEmpty ? 80 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
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
        cell.configure(page: pages[indexPath.row], source: source)
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !pages.isEmpty, indexPath.row < pages.count {
            LegacyHistoryStore.shared.update(
                source: source,
                manga: manga,
                chapter: chapter,
                pageIndex: indexPath.row,
                pageCount: pages.count
            )
        }

        let preloadCount = max(1, UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.prefetchPages"))
        let maxIndex = min(pages.count - 1, indexPath.row + preloadCount)
        guard maxIndex >= indexPath.row else { return }
        for pageIndex in (indexPath.row...maxIndex) {
            guard case .url(let url, let context) = pages[pageIndex].content else { continue }
            source.runner.getImageRequest(url: url, context: context) { result in
                if case .success(let request) = result {
                    var urlRequest = URLRequest(url: request.url)
                    urlRequest.httpMethod = request.method
                    urlRequest.httpBody = request.body
                    request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                    URLSession.shared.dataTask(with: urlRequest).resume()
                }
            }
        }
    }

    private func loadPages() {
        source.runner.getPageList(manga: manga, chapter: chapter) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let pages):
                    self.pages = pages
                    self.message = pages.isEmpty ? "No pages." : ""
                case .failure(let error):
                    self.message = error.localizedDescription
            }
            self.tableView.reloadData()
            self.scrollToInitialPageIfNeeded()
        }
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
        }
    }
}

final class LegacyPageImageCell: UITableViewCell {
    private let pageImageView = UIImageView()
    private let pageLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint!
    private var task: URLSessionDataTask?
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
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageLabel.text = nil
        pageImageView.isHidden = false
        heightConstraint.constant = 420
        onHeightChange = nil
    }

    func configure(page: AidokuRunnerLegacyPage, source: AidokuRunnerLegacySource) {
        switch page.content {
            case .url(let url, let context):
                pageLabel.text = "Loading..."
                source.runner.getImageRequest(url: url, context: context) { [weak self] result in
                    guard let self = self else { return }
                    var request: URLRequest
                    switch result {
                        case .success(let imageRequest):
                            var urlRequest = URLRequest(url: imageRequest.url)
                            urlRequest.httpMethod = imageRequest.method
                            urlRequest.httpBody = imageRequest.body
                            for header in imageRequest.headers {
                                urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
                            }
                            request = urlRequest
                        case .failure:
                            request = URLRequest(url: url)
                    }
                    if request.value(forHTTPHeaderField: "User-Agent") == nil {
                        request.setValue(
                            "Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                            forHTTPHeaderField: "User-Agent"
                        )
                    }
                    request.timeoutInterval = 30
                    self.load(request: request)
                }
            case .image(let data):
                setImage(from: data)
            case .text(let text):
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = text
            case .zipFile:
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = "ZIP pages are not supported in the legacy reader yet."
        }
    }

    private func load(request: URLRequest) {
        task?.cancel()
        task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data else {
                DispatchQueue.main.async {
                    self.pageImageView.isHidden = true
                    self.heightConstraint.constant = 180
                    self.pageLabel.text = "Image failed to load."
                    self.onHeightChange?()
                }
                return
            }
            self.setImage(from: data)
        }
        task?.resume()
    }

    private func setImage(from data: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let maxHeight = CGFloat(UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.maxImageHeight"))
            let image = LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let image = image {
                    self.pageLabel.text = nil
                    self.pageImageView.isHidden = false
                    self.pageImageView.image = image
                    let ratio = image.size.height / max(image.size.width, 1)
                    let targetHeight = min(max(UIScreen.main.bounds.width * ratio, 320), 2600)
                    self.heightConstraint.constant = targetHeight
                    self.onHeightChange?()
                } else {
                    self.pageImageView.isHidden = true
                    self.heightConstraint.constant = 180
                    self.pageLabel.text = "Image failed to load."
                    self.onHeightChange?()
                }
            }
        }
    }
}

private extension AidokuRunnerLegacyManga {
    func coverURL(relativeTo baseURL: URL?) -> URL? {
        guard let cover = cover?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty else {
            return nil
        }
        if let url = URL(string: cover), url.scheme != nil {
            return url
        }
        if let baseURL = baseURL {
            return URL(string: cover, relativeTo: baseURL)?.absoluteURL
        }
        return URL(string: cover)
    }
}

final class LegacySourceWebViewController: UIViewController, WKNavigationDelegate {
    private let initialURL: URL
    private let sourceTitle: String
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)

    init(url: URL, title: String) {
        self.initialURL = url
        self.sourceTitle = title
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(openInSafari)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadPage))
        ]
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
}
