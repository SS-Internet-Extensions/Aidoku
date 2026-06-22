//
//  LegacyKomgaBrowseViewController.swift
//  AidokuLegacy
//
//  Browse a configured self-hosted (Komga) server: a paginated, searchable series
//  list drilling into a book list, then opening a book in the existing reader via
//  LegacyKomgaRunner + a synthetic AidokuRunnerLegacySource.
//
//  iOS 12 / UIKit only: UITableViewController, manual cell reuse, completion-handler
//  networking. Lists are text-only (no cover thumbnails) to avoid authenticated
//  image loading in the list view; page images themselves are authenticated by the
//  runner's getImageRequest.
//

import UIKit

// MARK: - Series list

final class LegacyKomgaSeriesListViewController: UITableViewController, UISearchResultsUpdating {
    private let server: LegacyKomgaServer
    private let client: LegacyKomgaClient
    private let searchController = UISearchController(searchResultsController: nil)

    private var series: [LegacyKomgaSeries] = []
    private var page = 0
    private var isLoading = false
    private var reachedEnd = false
    private var query: String?
    private var pendingSearch: DispatchWorkItem?

    init(server: LegacyKomgaServer) {
        self.server = server
        self.client = LegacyKomgaClient(server: server)
        super.init(style: .plain)
        title = server.name.isEmpty ? server.kind.displayName : server.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = LegacyString("self_hosted.search_series.placeholder")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        loadNextPage(reset: true)
    }

    private func loadNextPage(reset: Bool) {
        if reset {
            page = 0
            reachedEnd = false
            series = []
            tableView.reloadData()
        }
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        let requestedPage = page
        client.listSeries(query: query, page: requestedPage) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                    case .success(let newSeries):
                        if newSeries.isEmpty {
                            self.reachedEnd = true
                        } else {
                            self.series.append(contentsOf: newSeries)
                            self.page = requestedPage + 1
                            if newSeries.count < 20 {
                                self.reachedEnd = true
                            }
                        }
                        self.tableView.reloadData()
                    case .failure(let error):
                        self.reachedEnd = true
                        if self.series.isEmpty {
                            self.showAlert(
                                title: LegacyString("self_hosted.load_series_failed.title"),
                                message: error.localizedDescription
                            )
                        }
                }
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newQuery = (text?.isEmpty == false) ? text : nil
        guard newQuery != query else { return }
        query = newQuery
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadNextPage(reset: true)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return series.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "Cell")
        let item = series[indexPath.row]
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = bookCountText(item.booksCount)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= series.count - 3 {
            loadNextPage(reset: false)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = series[indexPath.row]
        let booksVC = LegacyKomgaBooksViewController(server: server, series: item)
        navigationController?.pushViewController(booksVC, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LegacyString("button.ok"), style: .default))
        present(alert, animated: true)
    }

    private func bookCountText(_ count: Int) -> String {
        if count == 1 {
            return LegacyString("self_hosted.book_count.one")
        }
        return String(format: LegacyString("self_hosted.book_count.many"), count)
    }
}

// MARK: - Book list

final class LegacyKomgaBooksViewController: UITableViewController {
    private let server: LegacyKomgaServer
    private let series: LegacyKomgaSeries
    private let client: LegacyKomgaClient

    private var books: [LegacyKomgaBook] = []
    private var isLoading = false

    init(server: LegacyKomgaServer, series: LegacyKomgaSeries) {
        self.server = server
        self.series = series
        self.client = LegacyKomgaClient(server: server)
        super.init(style: .plain)
        title = series.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        load()
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        client.listBooks(seriesId: series.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                    case .success(let books):
                        self.books = books
                        self.tableView.reloadData()
                    case .failure(let error):
                        self.showAlert(
                            title: LegacyString("self_hosted.load_books_failed.title"),
                            message: error.localizedDescription
                        )
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return books.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "Cell")
        let book = books[indexPath.row]
        cell.textLabel?.text = book.title
        cell.detailTextLabel?.text = pageCountText(book.pageCount)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openReader(book: books[indexPath.row])
    }

    private func openReader(book: LegacyKomgaBook) {
        let runner = LegacyKomgaRunner(server: server, book: book)
        let info = AidokuRunnerLegacySourceInfo(
            info: .init(
                id: "komga",
                name: server.kind.displayName,
                altNames: nil,
                version: 1,
                url: server.baseURL,
                urls: nil,
                contentRating: .safe,
                languages: ["en"],
                minAppVersion: nil,
                maxAppVersion: nil
            ),
            listings: nil,
            config: nil
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AidokuLegacyKomgaSource-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = AidokuRunnerLegacySource(url: directory, info: info, runner: runner)
        let manga = AidokuRunnerLegacyManga(
            sourceKey: "komga",
            key: series.id,
            title: series.title,
            cover: nil,
            artists: nil,
            authors: nil,
            description: nil,
            url: nil,
            tags: nil,
            chapters: nil
        )
        let chapter = AidokuRunnerLegacyChapter(key: book.id, title: book.title, chapterNumber: book.number)
        let reader = LegacyReaderFactory.makeReader(source: source, manga: manga, chapter: chapter)
        navigationController?.pushViewController(reader, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LegacyString("button.ok"), style: .default))
        present(alert, animated: true)
    }

    private func pageCountText(_ count: Int) -> String {
        if count == 1 {
            return LegacyString("self_hosted.page_count.one")
        }
        return String(format: LegacyString("self_hosted.page_count.many"), count)
    }
}
