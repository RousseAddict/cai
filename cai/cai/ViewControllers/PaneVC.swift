import UIKit

// Live, interactive view of a single tmux pane. Owns a persistent SSHClient that lives on a
// dedicated SSHWorkThread (2MB stack — libssh2/OpenSSL key exchange overflows the small
// GCD-worker stack). The worker connects once, then loops:
//   drain queued send-keys commands -> `tmux capture-pane -p -t <session>` -> post text to
//   the main thread -> wait (poll interval OR until woken by new input) -> repeat,
// until the VC disappears. `capture-pane -p` returns the pane's currently visible screen, so
// each poll replaces the full text rather than appending.
//
// Input: the bottom bar's text field sends a line via `tmux send-keys -l -- <text>` followed
// by an Enter key. Commands are queued on an NSCondition so the worker is woken immediately
// (no up-to-poll-interval latency) and reuses the one connection.
final class PaneVC: UIViewController, UITextFieldDelegate {
    // Injected by the presenter before push. No custom designated initializer: a custom
    // init calling super.init on a VC subclass corrupts the heap on iOS 6 + the swapped
    // 5.1.5 runtime (see SessionsListVC) — construct via the default init and inject.
    var host: RemoteHost!
    var password: String!
    var session: String!

    private var textView: UITextView!
    private var inputBar: UIView!
    private var inputField: UITextField!
    private var sendBtn: UIButton!
    private var spinner: UIActivityIndicatorView!
    private var worker: SSHWorkThread?

    // Guards `stopped` and `pending`, and wakes the worker when input arrives or we stop.
    // Main thread writes; worker thread reads/waits.
    private let cond = NSCondition()
    private var stopped = false
    private var pending: [String] = []

    private static let pollInterval: TimeInterval = 1.5
    private static let inputBarH: CGFloat = 44

    override func viewDidLoad() {
        super.viewDidLoad()
        title = session
        view.backgroundColor = Theme.background
    }

    // Full UI layout in viewDidAppear (view.bounds is 0 in viewDidLoad for a pushed VC on
    // iOS 6). Guard so it only builds once.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard textView == nil else { return }

        textView = UITextView(frame: .zero)
        textView.isEditable = false
        textView.backgroundColor = Theme.rowBackground
        textView.textColor = Theme.primaryText
        textView.font = UIFont(name: "Menlo", size: 11) ?? UIFont.systemFont(ofSize: 11)
        view.addSubview(textView)
        // Tap the (non-editable) pane to dismiss the keyboard.
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)

        inputBar = UIView(frame: .zero)
        inputBar.backgroundColor = Theme.fieldBackground
        view.addSubview(inputBar)

        // Frames for these are computed in layout() from the bar's real width — setting them
        // here (while the bar is still .zero) then resizing distorts them via autoresizing.
        inputField = UITextField(frame: .zero)
        inputField.borderStyle = .roundedRect
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.returnKeyType = .send
        inputField.delegate = self
        inputBar.addSubview(inputField)

        sendBtn = UIButton(type: .custom)
        sendBtn.setTitle("Send", for: .normal)
        sendBtn.setTitleColor(.white, for: .normal)
        sendBtn.backgroundColor = Theme.accent
        sendBtn.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        inputBar.addSubview(sendBtn)

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        layout(bottomInset: 0)
        spinner.startAnimating()

        // keyboardWillChangeFrame covers show / hide / frame change in one handler.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setStopped()   // wakes the worker so it exits its loop and disconnects promptly
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func layout(bottomInset: CGFloat) {
        let b = view.bounds
        let barY = b.height - PaneVC.inputBarH - bottomInset
        inputBar.frame = CGRect(x: 0, y: barY, width: b.width, height: PaneVC.inputBarH)
        textView.frame = CGRect(x: 0, y: 0, width: b.width, height: barY)
        spinner.center = CGPoint(x: b.midX, y: barY / 2)

        // Lay out the field + button relative to the bar's real width.
        let pad: CGFloat = 8
        let btnW: CGFloat = 64
        let fieldH: CGFloat = 30
        let fieldY = (PaneVC.inputBarH - fieldH) / 2
        inputField.frame = CGRect(x: pad, y: fieldY,
                                  width: b.width - btnW - pad * 3, height: fieldH)
        sendBtn.frame = CGRect(x: b.width - btnW - pad, y: fieldY, width: btnW, height: fieldH)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let endInView = view.convert(end, from: nil)
        let overlap = max(0, view.bounds.maxY - endInView.minY)
        let dur = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: dur) { self.layout(bottomInset: overlap) }
    }

    @objc private func dismissKeyboard() {
        inputField.resignFirstResponder()
    }

    // MARK: - Input

    @objc private func sendTapped() {
        let text = inputField.text ?? ""
        guard !text.isEmpty else { return }
        inputField.text = ""
        let target = PaneVC.shellQuote(session)
        let literal = PaneVC.shellQuote(text)
        // -l sends the string literally; `--` stops option parsing so text starting with '-'
        // isn't mistaken for a flag. A separate Enter submits the line.
        let cmd = PaneVC.loginWrap(
            "tmux send-keys -t \(target) -l -- \(literal); tmux send-keys -t \(target) Enter")
        enqueue(cmd)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return false   // keep the keyboard up for the next line
    }

    // MARK: - Polling / worker

    private func startPolling() {
        guard worker == nil else { return }
        let host = self.host!, password = self.password!, session = self.session!
        let captureCmd = PaneVC.loginWrap("tmux capture-pane -p -t \(PaneVC.shellQuote(session)) 2>&1")
        let w = SSHWorkThread { [weak self] in
            let client = SSHClient()
            do {
                try client.connect(host: host.host, port: host.port,
                                   username: host.username, password: password)
            } catch {
                let msg = "\(error)"
                DispatchQueue.main.async { self?.connectFailed(msg) }
                return
            }
            // weak self -> if the VC has been deallocated, takePending/waitForNext coalesce
            // to a stop and we fall through to disconnect().
            while true {
                guard let sends = self?.takePending() else { break }
                for s in sends { _ = try? client.execute(s) }

                let out = (try? client.execute(captureCmd)) ?? ""
                DispatchQueue.main.async { self?.render(out) }

                guard let keepGoing = self?.waitForNext(), keepGoing else { break }
            }
            client.disconnect()
        }
        worker = w
        w.start()
    }

    private func render(_ text: String) {
        spinner.stopAnimating()
        // Preserve scroll position across refreshes so the view doesn't jump to the top.
        let offset = textView.contentOffset
        textView.text = text.isEmpty ? "(empty pane)" : text
        textView.contentOffset = offset
    }

    private func connectFailed(_ message: String) {
        spinner.stopAnimating()
        UIAlertView(title: "Connection failed", message: message,
                    delegate: nil, cancelButtonTitle: "OK").show()
        navigationController?.popViewController(animated: true)
    }

    // MARK: - Worker synchronization (main writes, worker reads/waits)

    private func enqueue(_ cmd: String) {
        cond.lock()
        pending.append(cmd)
        cond.signal()          // wake the worker so the send goes out immediately
        cond.unlock()
    }

    private func takePending() -> [String] {
        cond.lock(); defer { cond.unlock() }
        let p = pending
        pending.removeAll()
        return p
    }

    // Waits up to pollInterval, or returns early if input is queued / we're stopping.
    // Returns false when the VC is stopping (worker should exit its loop).
    private func waitForNext() -> Bool {
        cond.lock(); defer { cond.unlock() }
        if !stopped && pending.isEmpty {
            cond.wait(until: Date(timeIntervalSinceNow: PaneVC.pollInterval))
        }
        return !stopped
    }

    private func setStopped() {
        cond.lock()
        stopped = true
        cond.signal()
        cond.unlock()
    }

    // MARK: - Remote shell helpers (mirror SessionsListVC)

    // Single-quote for the remote shell so odd characters in the session name / input can't
    // break out of the command.
    private static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // SSH exec runs a non-login shell (no Homebrew PATH); re-run via a login shell so tmux
    // resolves.
    private static func loginWrap(_ command: String) -> String {
        return "$SHELL -lc " + shellQuote(command)
    }
}
