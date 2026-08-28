import UIKit

// The chat thread: a table of message bubbles plus a bottom input bar. Streams the assistant
// reply token-by-token from OpenRouter. Manual frame layout (iOS 6 conventions).
class ChatVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIAlertViewDelegate {

    private let conversation: Conversation
    private let tableView = UITableView()
    private let inputBar = UIView()
    private let textField = UITextField()
    private let sendButton = UIButton(type: .custom)
    private let loadingSpinner = UIActivityIndicatorView(style: .whiteLarge)

    private var keyboardHeight: CGFloat = 0
    private var isStreaming = false
    private var didSetup = false

    // Blinking block caret shown on the streaming assistant bubble.
    private var caretVisible = false
    private var caretTimer: Timer?

    // Coalesces streamed tokens: deltas accumulate into the model and the row is
    // re-rendered on a fixed cadence rather than on every token (avoids O(n^2) reparsing).
    private var refreshTimer: Timer?
    private var pendingRender = false

    private static let inputBarHeight: CGFloat = 58

    init(conversation: Conversation) {
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true   // hide the tab bar so the input bar sits at the screen bottom
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = conversation.title
        view.backgroundColor = Theme.background

        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                           .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(loadingSpinner)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Non-translucent bar so our content sits below it on iOS 7 (avoids iOS-7-only
        // edgesForExtendedLayout, which would crash on iOS 6).
        navigationController?.navigationBar.isTranslucent = false
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        // TTSPlayer is a singleton, so it would outlive this VC — weak self, and both
        // closures are cleared again in viewWillDisappear.
        TTSPlayer.shared.onStateChange = { [weak self] in self?.refreshSpeakButtons() }
        TTSPlayer.shared.onError = { [weak self] message in self?.showSpeechError(message) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
        // The repeating timers retain self; stop them so the VC can deallocate if popped mid-stream.
        caretTimer?.invalidate()
        caretTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Don't keep talking over whatever screen comes next.
        TTSPlayer.shared.stop()
        TTSPlayer.shared.onStateChange = nil
        TTSPlayer.shared.onError = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetup else { return }
        didSetup = true

        // Show the spinner, then build the table on the next runloop so it paints first.
        // Rendering rows parses markdown for every message, which can take a moment.
        loadingSpinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        loadingSpinner.startAnimating()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.setupUI()
            self.scrollToBottom(animated: false)
            self.loadingSpinner.stopAnimating()
        }
    }

    private func setupUI() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.background
        tableView.separatorStyle = .none
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        tableView.allowsSelection = false
        view.addSubview(tableView)

        // Tap anywhere in the message list to dismiss the keyboard.
        // cancelsTouchesInView = false so swipe-to-delete etc. still work.
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)

        inputBar.backgroundColor = Theme.inputBackground
        view.addSubview(inputBar)

        textField.backgroundColor = Theme.fieldBackground
        textField.textColor = Theme.primaryText
        textField.layer.cornerRadius = 8
        textField.layer.masksToBounds = true
        textField.font = UIFont.systemFont(ofSize: 16)
        textField.contentVerticalAlignment = .center   // keep text vertically centered
        textField.delegate = self
        textField.returnKeyType = .send
        textField.autocorrectionType = .no
        // Padding inside the field (left and right).
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        textField.leftViewMode = .always
        textField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        textField.rightViewMode = .always
        textField.attributedPlaceholder = NSAttributedString(
            string: "Message",
            attributes: [NSAttributedString.Key.foregroundColor: Theme.secondaryText])
        inputBar.addSubview(textField)

        // Circular blue send button with an up-arrow glyph (stoatold style).
        sendButton.setTitle("\u{2191}", for: .normal)
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.backgroundColor = Theme.accent
        sendButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        sendButton.titleEdgeInsets = UIEdgeInsets(top: -2, left: 3, bottom: 2, right: -3)
        sendButton.layer.masksToBounds = true
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        inputBar.addSubview(sendButton)

        layoutViews()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if didSetup { layoutViews() }
    }

    private func layoutViews() {
        let w = view.bounds.width
        let h = view.bounds.height
        let barH = ChatVC.inputBarHeight
        let barY = h - keyboardHeight - barH

        inputBar.frame = CGRect(x: 0, y: barY, width: w, height: barH)
        // Vertically center a square control of side `btn` with equal padding top/bottom.
        let btn: CGFloat = 38
        let pad = (barH - btn) / 2
        sendButton.frame = CGRect(x: w - pad - btn, y: pad, width: btn, height: btn)
        sendButton.layer.cornerRadius = btn / 2
        let tfX = pad
        let tfW = sendButton.frame.minX - pad - tfX
        textField.frame = CGRect(x: tfX, y: pad, width: tfW, height: btn)

        tableView.frame = CGRect(x: 0, y: 0, width: w, height: barY)
    }

    // MARK: - Keyboard

    @objc private func dismissKeyboard() {
        textField.resignFirstResponder()
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let endValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let endScreen = endValue.cgRectValue
        let endInView = view.convert(endScreen, from: nil)
        let overlap = max(0, view.bounds.maxY - endInView.minY)
        keyboardHeight = note.name == UIResponder.keyboardWillHideNotification ? 0 : overlap

        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration) {
            self.layoutViews()
        }
        scrollToBottom(animated: false)
    }

    // MARK: - Sending

    @objc private func sendTapped() {
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        guard Settings.hasAPIKey else {
            promptForKey()
            return
        }

        textField.text = ""
        conversation.messages.append(ChatMessage(role: ChatMessage.roleUser, content: text))
        conversation.deriveTitleIfNeeded()
        title = conversation.title
        // Placeholder assistant bubble that fills in as tokens stream.
        conversation.messages.append(ChatMessage(role: ChatMessage.roleAssistant, content: ""))
        tableView.reloadData()
        scrollToBottom(animated: false)
        ConversationStore.shared.save(conversation)

        setStreaming(true)
        let assistantIndex = conversation.messages.count - 1
        // Send history up to (but not including) the empty placeholder.
        var apiMessages = Array(conversation.messages[0..<assistantIndex])
        // Prepend the optional global system prompt.
        let systemPrompt = Settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            apiMessages.insert(ChatMessage(role: ChatMessage.roleSystem, content: systemPrompt), at: 0)
        }

        OpenRouterAPI.streamChat(
            messages: apiMessages,
            model: conversation.model,
            apiKey: Settings.apiKey,
            onDelta: { [weak self] delta in
                guard let self = self, assistantIndex < self.conversation.messages.count else { return }
                self.conversation.messages[assistantIndex].content += delta
                // Defer rendering to the refresh timer rather than reparsing on every token.
                self.pendingRender = true
            },
            onDone: { [weak self] error in
                guard let self = self else { return }
                if let error = error, assistantIndex < self.conversation.messages.count {
                    if self.conversation.messages[assistantIndex].content.isEmpty {
                        self.conversation.messages[assistantIndex].content = "[error] " + error
                    } else {
                        self.conversation.messages[assistantIndex].content += "\n\n[error] " + error
                    }
                    self.reloadLastRow()
                }
                // Flush the tail the refresh timer may not have picked up, then close the stream.
                self.feedSpeech(row: assistantIndex, complete: true)
                self.setStreaming(false)
                ConversationStore.shared.save(self.conversation)
            }
        )
    }

    private func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
        sendButton.isEnabled = !streaming
        sendButton.alpha = streaming ? 0.4 : 1.0

        caretTimer?.invalidate()
        caretTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if streaming {
            caretVisible = true
            pendingRender = false
            // Timer(withTimeInterval:repeats:block:) is iOS 10+; use the target/selector form.
            caretTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                              selector: #selector(blinkCaret),
                                              userInfo: nil, repeats: true)
            // ~10fps refresh: flushes accumulated tokens without reparsing per token.
            refreshTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self,
                                                selector: #selector(flushRender),
                                                userInfo: nil, repeats: true)
        } else {
            caretVisible = false
            reloadLastRow(scroll: false)   // final render, clears any lingering caret
        }
    }

    @objc private func blinkCaret() {
        caretVisible.toggle()
        reloadLastRow(scroll: false)
    }

    @objc private func flushRender() {
        guard pendingRender else { return }
        pendingRender = false
        feedSpeech(row: conversation.messages.count - 1, complete: false)
        reloadLastRow(scroll: true)
    }

    // MARK: - Speech

    // Messages have no id of their own, so a row is identified by conversation + index.
    // Rows are only ever appended, so an index stays valid for the life of the screen.
    private func speakKey(_ row: Int) -> String {
        return conversation.id + ":" + String(row)
    }

    private func toggleSpeak(row: Int) {
        guard row < conversation.messages.count else { return }
        let key = speakKey(row)
        if TTSPlayer.shared.isSpeaking(key: key) {
            TTSPlayer.shared.stop()
            return
        }
        guard Settings.hasAPIKey else {
            promptForKey()
            return
        }
        let text = MessageCell.speakableText(conversation.messages[row].content)
        // A reply that is still streaming is spoken as it arrives (see feedSpeech).
        TTSPlayer.shared.speak(key: key, text: text, isComplete: !isStreamingRow(row))
    }

    // Pushes the latest text of a streaming reply to the player. The isSpeaking guard also
    // keeps us from re-deriving speakable text 10x a second when nothing is being spoken.
    private func feedSpeech(row: Int, complete: Bool) {
        guard row >= 0, row < conversation.messages.count else { return }
        let key = speakKey(row)
        guard TTSPlayer.shared.isSpeaking(key: key) else { return }
        TTSPlayer.shared.append(key: key, fullText: MessageCell.speakableText(conversation.messages[row].content))
        if complete { TTSPlayer.shared.finish(key: key) }
    }

    private func refreshSpeakButtons() {
        guard let paths = tableView.indexPathsForVisibleRows else { return }
        for path in paths {
            guard let cell = tableView.cellForRow(at: path) as? MessageCell else { continue }
            cell.setSpeaking(TTSPlayer.shared.isSpeaking(key: speakKey(path.row)))
        }
    }

    private func showSpeechError(_ message: String) {
        UIAlertView(title: "Speech Failed", message: message,
                    delegate: nil, cancelButtonTitle: "OK").show()
    }

    private func promptForKey() {
        // UIAlertView (UIAlertController is iOS 8+). "Open Settings" is the non-cancel button.
        let alert = UIAlertView(title: "No API Key",
                                message: "Add your OpenRouter API key in Settings to start chatting.",
                                delegate: self,
                                cancelButtonTitle: "Cancel",
                                otherButtonTitles: "Open Settings")
        alert.show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        // Index 0 is the cancel button; the "Open Settings" button is index 1.
        guard buttonIndex == alertView.firstOtherButtonIndex else { return }
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return conversation.messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
        let row = indexPath.row
        cell.configure(with: conversation.messages[row],
                       showCaret: showCaret(at: row),
                       isSpeaking: TTSPlayer.shared.isSpeaking(key: speakKey(row)))
        cell.onSpeak = { [weak self] in self?.toggleSpeak(row: row) }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // Reserve caret space for the whole streaming duration (ignore blink phase)
        // so the row height stays stable as the caret blinks on and off.
        return MessageCell.height(for: conversation.messages[indexPath.row],
                                  cellWidth: tableView.bounds.width,
                                  showCaret: isStreamingRow(indexPath.row))
    }

    // The last row while an assistant reply is streaming.
    private func isStreamingRow(_ row: Int) -> Bool {
        guard isStreaming, row == conversation.messages.count - 1 else { return false }
        return !conversation.messages[row].isUser
    }

    // The caret is rendered only on the streaming row, in its "on" blink phase.
    private func showCaret(at row: Int) -> Bool {
        return isStreamingRow(row) && caretVisible
    }

    // MARK: - Helpers

    private func reloadLastRow(scroll: Bool = true) {
        let row = conversation.messages.count - 1
        guard row >= 0 else { return }
        tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        if scroll { scrollToBottom(animated: false) }
    }

    private func scrollToBottom(animated: Bool) {
        let count = conversation.messages.count
        guard count > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: count - 1, section: 0), at: .bottom, animated: animated)
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return false
    }
}
