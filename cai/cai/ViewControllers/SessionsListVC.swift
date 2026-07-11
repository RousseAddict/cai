import UIKit

// Lists the active tmux sessions on a RemoteHost. Connects off the main thread and
// runs `tmux list-sessions`. Tapping a session previews its captured pane (temporary;
// becomes a live read-only PaneVC next). Refresh re-runs the query.
class SessionsListVC: UITableViewController {
    // Injected by the presenter before push. NOT set via a custom designated initializer:
    // on iOS 6 with the swapped 5.1.5 runtime, a UITableViewController subclass that
    // declares its own init calling super.init(style:) corrupts the heap during
    // construction (SIGTRAP in free inside the init(nibName:bundle:) thunk). Constructing
    // via the inherited default init (like HostsListVC) and injecting properties avoids it.
    var host: RemoteHost!
    var password: String!
    private var sessions: [String] = []
    private var isBusy = false
    private var spinner: UIActivityIndicatorView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = host.displayName
        view.backgroundColor = Theme.background
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh, target: self, action: #selector(refresh))

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.hidesWhenStopped = true
        spinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                    .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(spinner)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if sessions.isEmpty && !isBusy { loadSessions() }
    }

    @objc private func refresh() { loadSessions() }

    // MARK: - SSH

    private func loadSessions() {
        guard !isBusy else { return }
        setBusy(true)
        let host = self.host!, password = self.password!
        let thread = SSHWorkThread {
            var names: [String] = []
            var message: String?
            let client = SSHClient()
            do {
                try client.connect(host: host.host, port: host.port,
                                   username: host.username, password: password)
                // -F prints just the session name per line; 2>&1 so "no server running"
                // (printed to stderr when tmux isn't up) is captured too.
                let out = try client.execute(SessionsListVC.loginWrap("tmux list-sessions -F '#{session_name}' 2>&1"))
                client.disconnect()
                names = SessionsListVC.parseSessions(out)
                if names.isEmpty {
                    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    message = trimmed.isEmpty ? "No active tmux sessions." : trimmed
                }
            } catch let error as SSHError {
                message = error.description
            } catch {
                message = "\(error)"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.setBusy(false)
                self.sessions = names
                self.tableView.reloadData()
                if names.isEmpty, let message = message {
                    self.showAlert(title: "tmux", message: message)
                }
            }
        }
        thread.start()
    }

    // Opens a live read-only view of the pane (PaneVC connects on its own worker thread).
    private func openPane(_ session: String) {
        let vc = PaneVC()
        vc.host = host
        vc.password = password
        vc.session = session
        navigationController?.pushViewController(vc, animated: true)
    }

    private static func parseSessions(_ output: String) -> [String] {
        var names: [String] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            // Filter common tmux error lines so they don't masquerade as sessions.
            if lower.contains("no server running") || lower.contains("error connecting")
                || lower.hasPrefix("no sessions") || lower.contains("command not found") {
                continue
            }
            names.append(line)
        }
        return names
    }

    // Single-quote for the remote shell (session names come from the remote, but quote
    // defensively so odd characters can't break out of the command).
    private static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // SSH exec runs a NON-login, non-interactive shell, so the user's PATH additions
    // (Homebrew's /opt/homebrew/bin etc., set in ~/.zprofile) are absent and tmux comes
    // back \"command not found\". Re-run the command through a login shell ($SHELL -lc) so
    // the profile files load PATH first. sshd already runs our command via `$SHELL -c`,
    // so $SHELL is defined in that outer context.
    private static func loginWrap(_ command: String) -> String {
        return "$SHELL -lc " + shellQuote(command)
    }

    // MARK: - UI helpers

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        view.isUserInteractionEnabled = !busy
        if busy {
            spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    private func showAlert(title: String, message: String) {
        UIAlertView(title: title, message: message, delegate: nil, cancelButtonTitle: "OK").show()
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sessions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "SessionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .default, reuseIdentifier: id)
        cell.backgroundColor = Theme.rowBackground
        cell.textLabel?.textColor = Theme.primaryText
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.text = sessions[indexPath.row]
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openPane(sessions[indexPath.row])
    }
}
