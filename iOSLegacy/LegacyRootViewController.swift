//
//  LegacyRootViewController.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit

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
        let message: String
        if installedSources.isEmpty {
            message = "No sources installed."
        } else {
            message = installedSources
                .map { "\($0.name) (\($0.key))" }
                .joined(separator: "\n")
        }
        showAlert(title: "Installed Sources", message: message)
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
                        self.showAlert(
                            title: "Source Installed",
                            message: "\(source.name) is ready in Installed Sources."
                        )
                    case .failure(let error):
                        self.showAlert(title: "Install Failed", message: error.localizedDescription)
                }
            }
        }
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
