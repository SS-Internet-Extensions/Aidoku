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
        cell.accessoryType = source.urls.isEmpty ? .none : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let source = sources[indexPath.row]
        guard let url = source.urls.first else {
            let alert = UIAlertController(
                title: source.name,
                message: "This source does not include a website URL.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let viewController = LegacySourceWebViewController(url: url, title: source.name)
        navigationController?.pushViewController(viewController, animated: true)
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
