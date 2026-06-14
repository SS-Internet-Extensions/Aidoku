//
//  LegacyLocalFilesViewController.swift
//  AidokuLegacy
//
//  Lists locally imported archives (cbz/zip/pdf) and lets the user add more via
//  a document picker. Tapping a row asks the host to open the reader through the
//  `onOpenChapter` closure, which receives the manga and its chapter so the host
//  can build pages via LegacyLocalFilePageProvider and present its reader.
//
//  iOS 12 / UIKit only: UITableViewController, swipe-to-delete via editing
//  actions, and the iOS 12 `UIDocumentPickerViewController(documentTypes:in:)`
//  initializer (NOT the iOS 14 `forOpeningContentTypes` API).
//

import UIKit

final class LegacyLocalFilesViewController: UITableViewController, UIDocumentPickerDelegate {
    /// Invoked when the user taps a chapter row. The host wires this to its
    /// reader: typically render pages off the main thread via
    /// `LegacyLocalFilePageProvider.pages(for:mangaId:on:completion:)` and push
    /// a reader view controller.
    var onOpenChapter: ((LegacyLocalManga, LegacyLocalChapter) -> Void)?

    private let store = LegacyLocalFileStore.shared
    private var mangaList: [LegacyLocalManga] = []
    private var changeObserver: NSObjectProtocol?
    private let cellIdentifier = "LegacyLocalFileCell"

    /// Background queue used while inspecting/importing picked archives.
    private let importQueue = DispatchQueue(label: "AidokuLegacy.localFilesViewController", qos: .userInitiated)

    init() {
        super.init(style: .plain)
        title = "Local Files"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let changeObserver = changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(presentImportPicker)
        )
        tableView.tableFooterView = UIView()

        changeObserver = NotificationCenter.default.addObserver(
            forName: .aidokuLegacyLocalFilesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }

        reload()
    }

    private func reload() {
        mangaList = store.mangaList
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    // MARK: - Importing

    @objc private func presentImportPicker() {
        // iOS 12-safe document types. Includes the standard ZIP/PDF UTIs plus a
        // generic data type so `.cbz` (which has no system UTI) can be picked.
        let documentTypes = [
            "public.zip-archive",
            "com.pkware.zip-archive",
            "com.adobe.pdf",
            "public.data"
        ]
        let picker = UIDocumentPickerViewController(documentTypes: documentTypes, in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        if #available(iOS 11.0, *) {
            picker.allowsMultipleSelection = true
        }
        present(picker, animated: true)
    }

    private func importArchives(at urls: [URL]) {
        guard !urls.isEmpty else { return }

        let loading = UIAlertController(title: nil, message: "Importing...", preferredStyle: .alert)
        present(loading, animated: true)

        importSequentially(urls: urls, index: 0, failures: []) { [weak self] failures in
            loading.dismiss(animated: true) {
                guard let self = self else { return }
                if !failures.isEmpty {
                    self.showAlert(
                        title: "Import Incomplete",
                        message: failures.joined(separator: "\n")
                    )
                }
            }
        }
    }

    /// Imports each picked URL in turn so memory use stays bounded.
    private func importSequentially(
        urls: [URL],
        index: Int,
        failures: [String],
        completion: @escaping ([String]) -> Void
    ) {
        guard index < urls.count else {
            completion(failures)
            return
        }
        let url = urls[index]
        store.importArchive(at: url) { [weak self] result in
            var failures = failures
            if case .failure(let error) = result {
                let name = url.lastPathComponent
                failures.append("\(name): \(error.localizedDescription)")
            }
            self?.importSequentially(urls: urls, index: index + 1, failures: failures, completion: completion)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importArchives(at: urls)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        importArchives(at: [url])
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return mangaList.isEmpty ? 1 : mangaList.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Use a subtitle cell so the page count/kind detail line is visible.
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellIdentifier)
        cell.imageView?.image = nil

        guard !mangaList.isEmpty else {
            cell.textLabel?.text = "No local files imported"
            cell.detailTextLabel?.text = nil
            cell.textLabel?.textColor = .gray
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let manga = mangaList[indexPath.row]
        let chapters = store.chapters(for: manga)
        let pageCount = chapters.first?.pageCount ?? 0
        let kindLabel = chapters.first.map { kindDisplayName($0.kind) } ?? ""

        cell.textLabel?.text = manga.title
        cell.textLabel?.textColor = nil
        var detail = "\(pageCount) page\(pageCount == 1 ? "" : "s")"
        if !kindLabel.isEmpty {
            detail += " - \(kindLabel)"
        }
        cell.detailTextLabel?.text = detail
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    private func kindDisplayName(_ kind: LegacyLocalChapterKind) -> String {
        switch kind {
            case .cbz:
                return "CBZ"
            case .zip:
                return "ZIP"
            case .pdf:
                return "PDF"
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !mangaList.isEmpty, indexPath.row < mangaList.count else { return }
        let manga = mangaList[indexPath.row]
        guard let chapter = store.chapters(for: manga).first else {
            showAlert(title: "Unavailable", message: "This item no longer has any readable pages.")
            return
        }
        onOpenChapter?(manga, chapter)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return !mangaList.isEmpty
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, !mangaList.isEmpty, indexPath.row < mangaList.count else { return }
        let manga = mangaList[indexPath.row]
        // The store posts a change notification; the observer reloads the table.
        store.delete(manga)
    }

    override func tableView(
        _ tableView: UITableView,
        titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath
    ) -> String? {
        return "Delete"
    }
}
