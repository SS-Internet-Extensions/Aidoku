//
//  LegacyLocalFilesViewController.swift
//  AidokuLegacy
//
//  Lists locally imported archives (cbz/zip/epub/pdf) and lets the user add more via
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

        store.scanLocalFolders()
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
        // iOS 12-safe document types. Includes standard ZIP/EPUB/PDF UTIs plus a
        // generic data type so `.cbz` (which has no system UTI) can be picked.
        let documentTypes = [
            "public.zip-archive",
            "com.pkware.zip-archive",
            "org.idpf.epub-container",
            "com.adobe.pdf",
            "public.folder",
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
        let itemCompletion: (Result<Void, Error>) -> Void = { [weak self] result in
            var failures = failures
            if case .failure(let error) = result {
                let name = url.lastPathComponent
                failures.append("\(name): \(error.localizedDescription)")
            }
            self?.importSequentially(urls: urls, index: index + 1, failures: failures, completion: completion)
        }
        if isDirectory(url) {
            store.importFolder(at: url, completion: itemCompletion)
        } else {
            store.importArchive(at: url) { result in
                itemCompletion(result.map { _ in () })
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
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

        cell.textLabel?.text = manga.title
        cell.textLabel?.textColor = nil
        if chapters.count == 1, let chapter = chapters.first {
            var detail = "\(chapter.pageCount) page\(chapter.pageCount == 1 ? "" : "s")"
            detail += " - \(kindDisplayName(chapter.kind))"
            if manga.localFolderPath != nil {
                detail += " - Local folder"
            }
            cell.detailTextLabel?.text = detail
        } else {
            let chapterCount = chapters.count
            var detail = "\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")"
            if manga.localFolderPath != nil {
                detail += " - Local folder"
            }
            cell.detailTextLabel?.text = detail
        }
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
            case .epub:
                return "EPUB"
            case .pdf:
                return "PDF"
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !mangaList.isEmpty, indexPath.row < mangaList.count else { return }
        let manga = mangaList[indexPath.row]
        let chapters = store.chapters(for: manga)
        guard !chapters.isEmpty else {
            showAlert(title: "Unavailable", message: "This item no longer has any readable pages.")
            return
        }
        if chapters.count == 1, let chapter = chapters.first {
            onOpenChapter?(manga, chapter)
        } else {
            let chaptersVC = LegacyLocalChaptersViewController(manga: manga)
            chaptersVC.onOpenChapter = onOpenChapter
            navigationController?.pushViewController(chaptersVC, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return !mangaList.isEmpty
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard !mangaList.isEmpty, indexPath.row < mangaList.count else { return nil }
        let manga = mangaList[indexPath.row]

        let delete = UITableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, _ in
            self?.store.delete(manga)
        }
        let edit = UITableViewRowAction(style: .normal, title: "Edit") { [weak self] _, _ in
            self?.presentMangaMetadataEditor(for: manga)
        }
        edit.backgroundColor = view.tintColor
        return [delete, edit]
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

    private func presentMangaMetadataEditor(for manga: LegacyLocalManga) {
        let alert = UIAlertController(title: "Edit Metadata", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Title"
            textField.text = manga.title
            textField.autocapitalizationType = .words
        }
        alert.addTextField { textField in
            textField.placeholder = "Description"
            textField.text = manga.description
            textField.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let title = alert?.textFields?[0].text ?? manga.title
            let description = alert?.textFields?[1].text
            self.store.updateMangaMetadata(mangaId: manga.id, title: title, description: description)
        })
        present(alert, animated: true)
    }
}

private final class LegacyLocalChaptersViewController: UITableViewController {
    var onOpenChapter: ((LegacyLocalManga, LegacyLocalChapter) -> Void)?

    private let store = LegacyLocalFileStore.shared
    private var manga: LegacyLocalManga
    private var chapters: [LegacyLocalChapter] = []
    private var changeObserver: NSObjectProtocol?
    private let cellIdentifier = "LegacyLocalChapterCell"

    init(manga: LegacyLocalManga) {
        self.manga = manga
        super.init(style: .plain)
        title = manga.title
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
        if let updated = store.mangaList.first(where: { $0.id == manga.id }) {
            manga = updated
            title = updated.title
            chapters = store.chapters(for: updated).sorted { lhs, rhs in
                legacyLocalChapterCompare(lhs, rhs)
            }
        } else {
            chapters = []
        }
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return chapters.isEmpty ? 1 : chapters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellIdentifier)
        guard !chapters.isEmpty else {
            cell.textLabel?.text = "No chapters"
            cell.detailTextLabel?.text = nil
            cell.textLabel?.textColor = .gray
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let chapter = chapters[indexPath.row]
        cell.textLabel?.text = chapterDisplayTitle(chapter)
        cell.textLabel?.textColor = nil
        cell.detailTextLabel?.text = "\(chapter.pageCount) page\(chapter.pageCount == 1 ? "" : "s") - \(kindDisplayName(chapter.kind))"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !chapters.isEmpty, indexPath.row < chapters.count else { return }
        onOpenChapter?(manga, chapters[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return !chapters.isEmpty
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard !chapters.isEmpty, indexPath.row < chapters.count else { return nil }
        let chapter = chapters[indexPath.row]
        let delete = UITableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, _ in
            guard let self = self else { return }
            self.store.deleteChapter(mangaId: self.manga.id, chapter: chapter)
        }
        let edit = UITableViewRowAction(style: .normal, title: "Edit") { [weak self] _, _ in
            self?.presentChapterMetadataEditor(for: chapter)
        }
        edit.backgroundColor = view.tintColor
        return [delete, edit]
    }

    private func presentChapterMetadataEditor(for chapter: LegacyLocalChapter) {
        let alert = UIAlertController(title: "Edit Chapter", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Title"
            textField.text = chapter.title
            textField.autocapitalizationType = .words
        }
        alert.addTextField { textField in
            textField.placeholder = "Volume"
            textField.text = chapter.volumeNumber.map { LegacyLocalChaptersViewController.formatNumber($0) }
            textField.keyboardType = .decimalPad
        }
        alert.addTextField { textField in
            textField.placeholder = "Chapter"
            textField.text = chapter.chapterNumber.map { LegacyLocalChaptersViewController.formatNumber($0) }
            textField.keyboardType = .decimalPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let title = alert?.textFields?[0].text ?? chapter.title
            let volume = LegacyLocalChaptersViewController.parseNumber(alert?.textFields?[1].text)
            let chapterNumber = LegacyLocalChaptersViewController.parseNumber(alert?.textFields?[2].text)
            self.store.updateChapterMetadata(
                mangaId: self.manga.id,
                chapterId: chapter.id,
                title: title,
                volumeNumber: volume,
                chapterNumber: chapterNumber
            )
        })
        present(alert, animated: true)
    }

    private func chapterDisplayTitle(_ chapter: LegacyLocalChapter) -> String {
        var prefix: [String] = []
        if let volume = chapter.volumeNumber {
            prefix.append("Vol. \(Self.formatNumber(volume))")
        }
        if let number = chapter.chapterNumber {
            prefix.append("Ch. \(Self.formatNumber(number))")
        }
        guard !prefix.isEmpty else {
            return chapter.title
        }
        return "\(prefix.joined(separator: " ")) - \(chapter.title)"
    }

    private func kindDisplayName(_ kind: LegacyLocalChapterKind) -> String {
        switch kind {
            case .cbz:
                return "CBZ"
            case .zip:
                return "ZIP"
            case .epub:
                return "EPUB"
            case .pdf:
                return "PDF"
        }
    }

    private static func parseNumber(_ value: String?) -> Float? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return Float(value)
    }

    private static func formatNumber(_ value: Float) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

private func legacyLocalChapterCompare(_ lhs: LegacyLocalChapter, _ rhs: LegacyLocalChapter) -> Bool {
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
    return legacyLocalNaturalCompare(lhs.title, rhs.title)
}
