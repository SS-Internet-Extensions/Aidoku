//
//  LegacyKomgaServerListViewController.swift
//  AidokuLegacy
//
//  Lists configured self-hosted (Komga / Kavita) servers and hosts an add/edit form.
//  iOS 12 / UIKit only: grouped UITableViewController, manual UITableViewCell reuse,
//  swipe-to-delete via the editing-style commit callback, and plain UITextFields
//  embedded in cells (identified by tag) instead of any custom cell classes.
//
//  Tapping a stored server invokes `onSelectServer` so the host can open that
//  server's catalog later (the reader runner is wired separately on the host side).
//

import UIKit

final class LegacyKomgaServerListViewController: UITableViewController {
    // Invoked when the user taps a configured server row.
    var onSelectServer: ((LegacyKomgaServer) -> Void)?

    private let store = LegacyKomgaServerStore.shared
    private var servers: [LegacyKomgaServer] = []
    private var changeObserver: NSObjectProtocol?
    private let cellIdentifier = "LegacyKomgaServerCell"

    init() {
        super.init(style: .grouped)
        title = "Self-Hosted Servers"
    }

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

        changeObserver = NotificationCenter.default.addObserver(
            forName: .aidokuLegacySelfHostedServersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }

        reload()
    }

    private func reload() {
        servers = store.servers
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    @objc private func presentAddForm() {
        let form = LegacyKomgaServerFormViewController(server: nil)
        form.onSaved = { [weak self] in
            self?.reload()
        }
        navigationController?.pushViewController(form, animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        // Section 0: configured servers (or an empty-state row). Section 1: add row.
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return servers.isEmpty ? 1 : servers.count
        }
        return 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellIdentifier)
        cell.detailTextLabel?.text = nil
        cell.textLabel?.textColor = nil

        if indexPath.section == 1 {
            cell.textLabel?.text = "+ Add Server"
            cell.textLabel?.textAlignment = .center
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
        }

        cell.textLabel?.textAlignment = .natural

        guard !servers.isEmpty else {
            cell.textLabel?.text = "No servers configured"
            cell.textLabel?.textColor = .gray
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let server = servers[indexPath.row]
        cell.textLabel?.text = server.name.isEmpty ? server.baseURL : server.name
        cell.detailTextLabel?.text = "\(server.kind.displayName) - \(server.baseURL)"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 1 {
            presentAddForm()
            return
        }

        guard !servers.isEmpty, indexPath.row < servers.count else { return }
        onSelectServer?(servers[indexPath.row])
    }

    override func tableView(
        _ tableView: UITableView,
        accessoryButtonTappedForRowWith indexPath: IndexPath
    ) {
        editServer(at: indexPath)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 0 && !servers.isEmpty
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard
            editingStyle == .delete,
            indexPath.section == 0,
            !servers.isEmpty,
            indexPath.row < servers.count
        else {
            return
        }
        // The store posts a change notification; the observer reloads the table.
        store.remove(id: servers[indexPath.row].id)
    }

    override func tableView(
        _ tableView: UITableView,
        titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath
    ) -> String? {
        return "Delete"
    }

    private func editServer(at indexPath: IndexPath) {
        guard indexPath.section == 0, !servers.isEmpty, indexPath.row < servers.count else { return }
        let form = LegacyKomgaServerFormViewController(server: servers[indexPath.row])
        form.onSaved = { [weak self] in
            self?.reload()
        }
        navigationController?.pushViewController(form, animated: true)
    }
}

// MARK: - Add/Edit form

// Form for creating or editing a single server record. Uses plain cells with
// embedded UITextFields (tagged) and a segmented control for the server kind. A
// footer "Test & Save" button validates the credentials via a live listSeries call
// before persisting and popping.
final class LegacyKomgaServerFormViewController: UITableViewController, UITextFieldDelegate {
    // Invoked after a successful save.
    var onSaved: (() -> Void)?

    private let store = LegacyKomgaServerStore.shared
    private let existing: LegacyKomgaServer?

    // Field tags for the embedded text fields.
    private enum FieldTag: Int {
        case name = 1
        case baseURL = 2
        case username = 3
        case password = 4
    }

    private var nameValue: String
    private var baseURLValue: String
    private var usernameValue: String
    private var passwordValue: String
    private var kindValue: LegacyKomgaServerKind

    private let kindControl = UISegmentedControl(items: [
        LegacyKomgaServerKind.komga.displayName,
        LegacyKomgaServerKind.kavita.displayName
    ])

    init(server: LegacyKomgaServer?) {
        self.existing = server
        self.nameValue = server?.name ?? ""
        self.baseURLValue = server?.baseURL ?? ""
        self.usernameValue = server?.username ?? ""
        self.passwordValue = server?.password ?? ""
        self.kindValue = server?.kind ?? .komga
        super.init(style: .grouped)
        title = server == nil ? "Add Server" : "Edit Server"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        kindControl.selectedSegmentIndex = (kindValue == .kavita) ? 1 : 0
        kindControl.addTarget(self, action: #selector(kindChanged), for: .valueChanged)
    }

    @objc private func kindChanged() {
        kindValue = kindControl.selectedSegmentIndex == 1 ? .kavita : .komga
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        // Section 0: text fields. Section 1: kind. Section 2: test & save button.
        return 3
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
            case 0:
                return 4
            default:
                return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
            case 0:
                return "Server"
            case 1:
                return "Type"
            default:
                return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            return textFieldCell(for: indexPath.row)
        }
        if indexPath.section == 1 {
            return kindCell()
        }
        return saveCell()
    }

    private func textFieldCell(for row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let field = UITextField(frame: CGRect(x: 16, y: 0, width: cell.contentView.bounds.width - 32, height: 44))
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        field.delegate = self
        field.addTarget(self, action: #selector(textFieldChanged(_:)), for: .editingChanged)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done

        switch row {
            case 0:
                field.tag = FieldTag.name.rawValue
                field.placeholder = "Name"
                field.text = nameValue
            case 1:
                field.tag = FieldTag.baseURL.rawValue
                field.placeholder = "https://komga.example.com"
                field.text = baseURLValue
                field.keyboardType = .URL
            case 2:
                field.tag = FieldTag.username.rawValue
                field.placeholder = "Username"
                field.text = usernameValue
            default:
                field.tag = FieldTag.password.rawValue
                field.placeholder = "Password"
                field.text = passwordValue
                field.isSecureTextEntry = true
        }

        cell.contentView.addSubview(field)
        return cell
    }

    private func kindCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        kindControl.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(kindControl)
        NSLayoutConstraint.activate([
            kindControl.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            kindControl.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            kindControl.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            kindControl.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8)
        ])
        return cell
    }

    private func saveCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "Test & Save"
        cell.textLabel?.textAlignment = .center
        cell.textLabel?.textColor = view.tintColor
        cell.selectionStyle = .default
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2 else { return }
        view.endEditing(true)
        testAndSave()
    }

    // MARK: - Field editing

    @objc private func textFieldChanged(_ field: UITextField) {
        let value = field.text ?? ""
        switch FieldTag(rawValue: field.tag) {
            case .name:
                nameValue = value
            case .baseURL:
                baseURLValue = value
            case .username:
                usernameValue = value
            case .password:
                passwordValue = value
            case .none:
                break
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - Validation & save

    private func testAndSave() {
        let trimmedName = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURLValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidate = LegacyKomgaServer(
            id: existing?.id ?? UUID().uuidString,
            name: trimmedName.isEmpty ? trimmedURL : trimmedName,
            baseURL: trimmedURL,
            username: usernameValue,
            password: passwordValue,
            kind: kindValue
        )

        guard candidate.url != nil else {
            showAlert(title: "Invalid URL", message: "Enter a valid server address (e.g. https://komga.example.com).")
            return
        }

        let loading = UIAlertController(title: nil, message: "Testing...", preferredStyle: .alert)
        present(loading, animated: true)

        let client = LegacyKomgaClient(server: candidate)
        client.listSeries(query: nil, page: 0) { [weak self] result in
            DispatchQueue.main.async {
                loading.dismiss(animated: true) {
                    guard let self = self else { return }
                    switch result {
                        case .success:
                            self.save(candidate)
                        case .failure(let error):
                            self.showAlert(
                                title: "Connection Failed",
                                message: error.localizedDescription
                            )
                    }
                }
            }
        }
    }

    private func save(_ server: LegacyKomgaServer) {
        if existing != nil {
            store.update(server)
        } else {
            store.add(server)
        }
        onSaved?()
        navigationController?.popViewController(animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
