import UIKit

// Tab root: a list of saved conversations. "+" starts a new chat; the gear opens Settings.
class ConversationListVC: UITableViewController {
    private var conversations: [Conversation] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chats"
        view.backgroundColor = Theme.background
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Settings", style: .plain, target: self, action: #selector(openSettings))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(newChat))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        conversations = ConversationStore.shared.all()
        tableView.reloadData()
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }

    @objc private func newChat() {
        let convo = Conversation(model: Settings.defaultModel)
        navigationController?.pushViewController(ChatVC(conversation: convo), animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return conversations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "ConvoCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let convo = conversations[indexPath.row]
        cell.backgroundColor = Theme.rowBackground
        cell.textLabel?.textColor = Theme.primaryText
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.text = convo.title
        cell.detailTextLabel?.textColor = Theme.secondaryText
        cell.detailTextLabel?.backgroundColor = .clear
        cell.detailTextLabel?.text = convo.lastMessagePreview
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let convo = conversations[indexPath.row]
        navigationController?.pushViewController(ChatVC(conversation: convo), animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let convo = conversations[indexPath.row]
        ConversationStore.shared.delete(convo)
        conversations.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
