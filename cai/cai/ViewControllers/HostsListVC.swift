import UIKit

// Tab 2 root: saved SSH hosts. "+" adds a host; the (i) accessory edits one.
// Tapping a row opens that host's tmux session list (SessionsListVC connects).
class HostsListVC: UITableViewController {
    private var hosts: [RemoteHost] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Remote"
        view.backgroundColor = Theme.background
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addHost))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        hosts = RemoteHostStore.shared.all()
        tableView.reloadData()
    }

    @objc private func addHost() {
        presentEditor(for: nil)
    }

    private func presentEditor(for host: RemoteHost?) {
        let editor = HostEditVC(host: host)
        editor.onSave = { [weak self] in self?.reload() }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true, completion: nil)
    }

    private func open(_ host: RemoteHost) {
        guard let password = Keychain.password(for: host.id) else {
            let alert = UIAlertView(title: "No Password",
                                    message: "Edit this host to set its password first.",
                                    delegate: nil, cancelButtonTitle: "OK")
            alert.show()
            return
        }
        let vc = SessionsListVC()
        vc.host = host
        vc.password = password
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return hosts.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "HostCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let host = hosts[indexPath.row]
        cell.backgroundColor = Theme.rowBackground
        cell.textLabel?.textColor = Theme.primaryText
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.text = host.displayName
        cell.detailTextLabel?.textColor = Theme.secondaryText
        cell.detailTextLabel?.backgroundColor = .clear
        cell.detailTextLabel?.text = host.connectionString
        cell.accessoryType = .detailDisclosureButton
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(hosts[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        presentEditor(for: hosts[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let host = hosts[indexPath.row]
        RemoteHostStore.shared.delete(host)
        hosts.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
