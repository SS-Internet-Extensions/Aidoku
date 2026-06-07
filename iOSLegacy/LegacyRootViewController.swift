//
//  LegacyRootViewController.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit
import WebKit

enum LegacyPalette {
    static let background = UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
    static let panel = UIColor.white
    static let primaryText = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    static let secondaryText = UIColor(red: 0.34, green: 0.35, blue: 0.38, alpha: 1)
    static let accent = UIColor(red: 0.83, green: 0.12, blue: 0.36, alpha: 1)
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

        title = "Aidoku Legacy"
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
        navigationItem.rightBarButtonItem?.isEnabled = !installedSources.isEmpty
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
            cell.textLabel?.text = loadingText
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let source = visibleSources[indexPath.row]
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
    private let sources: [AidokuRunnerLegacySource]

    init(sources: [AidokuRunnerLegacySource]) {
        self.sources = sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(style: .plain)
        title = "Installed Sources"
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
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sources.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "InstalledSourceCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "InstalledSourceCell")
        let source = sources[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.textLabel?.text = source.name
        cell.detailTextLabel?.text = "\(source.key)  v\(source.version)  \(source.languages.joined(separator: ", "))"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let source = sources[indexPath.row]
        navigationController?.pushViewController(LegacySourceMenuViewController(source: source), animated: true)
    }
}

final class LegacySourceMenuViewController: UITableViewController {
    private enum Row {
        case search
        case listing(AidokuRunnerLegacyListing)
        case website(URL)
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
        rows = [.search]
        rows.append(contentsOf: source.staticListings.map { .listing($0) })
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
        switch rows[indexPath.row] {
            case .search:
                cell.textLabel?.text = "Search Manga"
                cell.detailTextLabel?.text = "Run get_search_manga_list"
            case .listing(let listing):
                cell.textLabel?.text = listing.name
                cell.detailTextLabel?.text = "Run get_manga_list"
            case .website(let url):
                cell.textLabel?.text = "Browse Website"
                cell.detailTextLabel?.text = url.absoluteString
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
            case .search:
                navigationController?.pushViewController(LegacyMangaListViewController(source: source, listing: nil), animated: true)
            case .listing(let listing):
                navigationController?.pushViewController(LegacyMangaListViewController(source: source, listing: listing), animated: true)
            case .website(let url):
                navigationController?.pushViewController(LegacySourceWebViewController(url: url, title: source.name), animated: true)
        }
    }
}

final class LegacyMangaListViewController: UITableViewController {
    private let source: AidokuRunnerLegacySource
    private let listing: AidokuRunnerLegacyListing?
    private let searchController = UISearchController(searchResultsController: nil)

    private var entries: [AidokuRunnerLegacyManga] = []
    private var page = 1
    private var hasNextPage = false
    private var isLoading = false
    private var message = "Enter a search term."

    init(source: AidokuRunnerLegacySource, listing: AidokuRunnerLegacyListing?) {
        self.source = source
        self.listing = listing
        super.init(style: .plain)
        title = listing?.name ?? "Search"
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

        searchController.searchBar.placeholder = "Search manga"
        searchController.searchBar.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        definesPresentationContext = true

        if listing != nil {
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
            cell.textLabel?.text = isLoading ? "Loading..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.row == entries.count {
            cell.textLabel?.text = isLoading ? "Loading..." : "Load Next Page"
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
        }

        let manga = entries[indexPath.row]
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
                    self.entries.append(contentsOf: pageResult.entries)
                    self.hasNextPage = pageResult.hasNextPage
                    self.page += 1
                    self.message = self.entries.isEmpty ? "No manga found." : ""
                case .failure(let error):
                    self.message = error.localizedDescription
            }
            self.tableView.reloadData()
        }

        if let listing = listing {
            source.runner.getMangaList(listing: listing, page: page, completion: completion)
        } else {
            let query = searchController.searchBar.text ?? ""
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isLoading = false
                message = "Enter a search term."
                tableView.reloadData()
                return
            }
            source.runner.getSearchMangaList(query: query, page: page, filters: [], completion: completion)
        }
    }
}

extension LegacyMangaListViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        load(reset: true)
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

        if indexPath.section == 0 {
            cell.textLabel?.text = manga.title
            cell.detailTextLabel?.text = errorMessage ?? manga.description ?? manga.authors?.joined(separator: ", ") ?? "No description."
            cell.accessoryType = .none
            return cell
        }

        guard let chapters = manga.chapters, !chapters.isEmpty else {
            cell.textLabel?.text = isLoading ? "Loading chapters..." : "No chapters."
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            return cell
        }

        let chapter = chapters[indexPath.row]
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
            self.tableView.reloadData()
        }
    }
}

final class LegacyReaderViewController: UITableViewController {
    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let chapter: AidokuRunnerLegacyChapter
    private var pages: [AidokuRunnerLegacyPage] = []
    private var message = "Loading pages..."

    init(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga, chapter: AidokuRunnerLegacyChapter) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
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
        cell.configure(page: pages[indexPath.row], source: source)
        return cell
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
        }
    }
}

final class LegacyPageImageCell: UITableViewCell {
    private let pageImageView = UIImageView()
    private let pageLabel = UILabel()
    private var task: URLSessionDataTask?

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
        NSLayoutConstraint.activate([
            pageImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageImageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
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
    }

    func configure(page: AidokuRunnerLegacyPage, source: AidokuRunnerLegacySource) {
        switch page.content {
            case .url(let url):
                pageLabel.text = "Loading..."
                source.runner.getImageRequest(url: url) { [weak self] result in
                    guard let self = self else { return }
                    let request: URLRequest
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
                    self.load(request: request)
                }
            case .text(let text):
                pageImageView.isHidden = true
                pageLabel.text = text
            case .zipFile:
                pageImageView.isHidden = true
                pageLabel.text = "ZIP pages are not supported in the legacy reader yet."
        }
    }

    private func load(request: URLRequest) {
        task?.cancel()
        task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                if let image = image {
                    self.pageLabel.text = nil
                    self.pageImageView.image = image
                    let ratio = image.size.height / max(image.size.width, 1)
                    let targetHeight = min(max(UIScreen.main.bounds.width * ratio, 300), 2400)
                    if let heightConstraint = self.pageImageView.constraints.first(where: { $0.firstAttribute == .height }) {
                        heightConstraint.constant = targetHeight
                    }
                } else {
                    self.pageImageView.isHidden = true
                    self.pageLabel.text = "Image failed to load."
                }
            }
        }
        task?.resume()
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
        UIApplication.shared.openURL(url)
    }
}
