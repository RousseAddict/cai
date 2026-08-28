import UIKit
import AVFoundation

// Settings: the OpenRouter API key and the default model id used for new conversations.
// Both persist to UserDefaults via `Settings`. Manual frame layout (iOS 6 conventions).
class SettingsVC: UIViewController, UITextFieldDelegate {

    private let scrollView = UIScrollView()
    private let keyLabel = UILabel()
    private let keyField = UITextField()
    private let modelLabel = UILabel()
    private let modelField = UITextField()
    private let ttsModelLabel = UILabel()
    private let ttsModelField = UITextField()
    private let ttsVoiceLabel = UILabel()
    private let ttsVoiceField = UITextField()
    private let testButton = UIButton(type: .custom)
    private let testStatusLabel = UILabel()
    private let promptLabel = UILabel()
    private let promptView = UITextView()
    private let noteLabel = UILabel()

    // Retains the player: AVAudioPlayer stops and deallocates if nothing holds it.
    private static var testPlayer: AVAudioPlayer?

    private var keyboardHeight: CGFloat = 0
    private var didSetup = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = Theme.background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.isTranslucent = false
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Persist whatever is currently typed when leaving the screen.
        save()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetup else { return }
        didSetup = true
        setupUI()
    }

    private func setupUI() {
        scrollView.backgroundColor = Theme.background
        // keyboardDismissMode is iOS 7+ (unrecognized selector / crash on iOS 6).
        if scrollView.responds(to: #selector(setter: UIScrollView.keyboardDismissMode)) {
            scrollView.keyboardDismissMode = .interactive
        }
        view.addSubview(scrollView)

        keyLabel.text = "OpenRouter API Key"
        keyLabel.textColor = Theme.secondaryText
        keyLabel.backgroundColor = .clear
        keyLabel.font = UIFont.boldSystemFont(ofSize: 13)
        scrollView.addSubview(keyLabel)

        styleField(keyField)
        keyField.placeholder = "sk-or-..."
        keyField.text = Settings.apiKey
        keyField.isSecureTextEntry = true
        keyField.returnKeyType = .done
        scrollView.addSubview(keyField)

        modelLabel.text = "Default Model"
        modelLabel.textColor = Theme.secondaryText
        modelLabel.backgroundColor = .clear
        modelLabel.font = UIFont.boldSystemFont(ofSize: 13)
        scrollView.addSubview(modelLabel)

        styleField(modelField)
        modelField.placeholder = Settings.fallbackModel
        modelField.text = Settings.defaultModel
        modelField.returnKeyType = .done
        scrollView.addSubview(modelField)

        ttsModelLabel.text = "Voice Model"
        ttsModelLabel.textColor = Theme.secondaryText
        ttsModelLabel.backgroundColor = .clear
        ttsModelLabel.font = UIFont.boldSystemFont(ofSize: 13)
        scrollView.addSubview(ttsModelLabel)

        styleField(ttsModelField)
        ttsModelField.placeholder = Settings.fallbackTTSModel
        ttsModelField.text = Settings.ttsModel
        ttsModelField.returnKeyType = .done
        scrollView.addSubview(ttsModelField)

        ttsVoiceLabel.text = "Voice"
        ttsVoiceLabel.textColor = Theme.secondaryText
        ttsVoiceLabel.backgroundColor = .clear
        ttsVoiceLabel.font = UIFont.boldSystemFont(ofSize: 13)
        scrollView.addSubview(ttsVoiceLabel)

        styleField(ttsVoiceField)
        ttsVoiceField.placeholder = Settings.fallbackTTSVoice
        ttsVoiceField.text = Settings.ttsVoice
        ttsVoiceField.returnKeyType = .done
        scrollView.addSubview(ttsVoiceField)

        // .custom: .system ignores setTitleColor/backgroundColor on iOS 6.
        testButton.setTitle("Test Voice", for: .normal)
        testButton.setTitleColor(.white, for: .normal)
        testButton.backgroundColor = Theme.accent
        testButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        testButton.layer.cornerRadius = 10
        testButton.addTarget(self, action: #selector(testVoiceTapped), for: .touchUpInside)
        scrollView.addSubview(testButton)

        testStatusLabel.textColor = Theme.secondaryText
        testStatusLabel.backgroundColor = .clear
        testStatusLabel.font = UIFont.systemFont(ofSize: 13)
        testStatusLabel.numberOfLines = 0
        scrollView.addSubview(testStatusLabel)

        promptLabel.text = "System Prompt (optional)"
        promptLabel.textColor = Theme.secondaryText
        promptLabel.backgroundColor = .clear
        promptLabel.font = UIFont.boldSystemFont(ofSize: 13)
        scrollView.addSubview(promptLabel)

        promptView.backgroundColor = Theme.fieldBackground
        promptView.textColor = Theme.primaryText
        promptView.layer.cornerRadius = 10
        promptView.layer.masksToBounds = true
        promptView.font = UIFont.systemFont(ofSize: 16)
        promptView.autocorrectionType = .no
        promptView.text = Settings.systemPrompt
        // textContainerInset is iOS 7+ (TextKit) — guard so iOS 6 doesn't crash on the setter.
        if promptView.responds(to: #selector(setter: UITextView.textContainerInset)) {
            promptView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        }
        scrollView.addSubview(promptView)

        noteLabel.text = "New chats use the default model above. The system prompt is sent at the start of every chat. Free models end in \":free\". Get a key at openrouter.ai/keys."
        noteLabel.textColor = Theme.secondaryText
        noteLabel.backgroundColor = .clear
        noteLabel.font = UIFont.systemFont(ofSize: 13)
        noteLabel.numberOfLines = 0
        scrollView.addSubview(noteLabel)

        layoutViews()
    }

    private func styleField(_ field: UITextField) {
        field.backgroundColor = Theme.fieldBackground
        field.textColor = Theme.primaryText
        field.layer.cornerRadius = 10
        field.layer.masksToBounds = true
        field.font = UIFont.systemFont(ofSize: 16)
        field.contentVerticalAlignment = .center   // keep text vertically centered
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.attributedPlaceholder = NSAttributedString(
            string: field.placeholder ?? "",
            attributes: [NSAttributedString.Key.foregroundColor: Theme.secondaryText])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if didSetup { layoutViews() }
    }

    private func layoutViews() {
        let w = view.bounds.width
        let margin: CGFloat = 16
        let fieldW = w - 2 * margin
        let fieldH: CGFloat = 54
        var y: CGFloat = 24

        scrollView.frame = CGRect(x: 0, y: 0, width: w, height: view.bounds.height - keyboardHeight)

        keyLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: 18)
        y += 22
        keyField.frame = CGRect(x: margin, y: y, width: fieldW, height: fieldH)
        y += fieldH + 24

        modelLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: 18)
        y += 22
        modelField.frame = CGRect(x: margin, y: y, width: fieldW, height: fieldH)
        y += fieldH + 24

        ttsModelLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: 18)
        y += 22
        ttsModelField.frame = CGRect(x: margin, y: y, width: fieldW, height: fieldH)
        y += fieldH + 24

        ttsVoiceLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: 18)
        y += 22
        ttsVoiceField.frame = CGRect(x: margin, y: y, width: fieldW, height: fieldH)
        y += fieldH + 16

        testButton.frame = CGRect(x: margin, y: y, width: fieldW, height: 46)
        y += 46 + 8

        let statusSize = testStatusLabel.sizeThatFits(CGSize(width: fieldW, height: .greatestFiniteMagnitude))
        testStatusLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: ceil(statusSize.height))
        y += ceil(statusSize.height) + 24

        promptLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: 18)
        y += 22
        promptView.frame = CGRect(x: margin, y: y, width: fieldW, height: 120)
        y += 120 + 20

        let noteSize = noteLabel.sizeThatFits(CGSize(width: fieldW, height: .greatestFiniteMagnitude))
        noteLabel.frame = CGRect(x: margin, y: y, width: fieldW, height: ceil(noteSize.height))
        y += ceil(noteSize.height) + 20

        scrollView.contentSize = CGSize(width: w, height: y)
    }

    // MARK: - Persistence

    private func save() {
        Settings.apiKey = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (modelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.defaultModel = model.isEmpty ? Settings.fallbackModel : model
        Settings.systemPrompt = (promptView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ttsModel = (ttsModelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.ttsModel = ttsModel.isEmpty ? Settings.fallbackTTSModel : ttsModel
        let ttsVoice = (ttsVoiceField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.ttsVoice = ttsVoice.isEmpty ? Settings.fallbackTTSVoice : ttsVoice
    }

    // MARK: - Voice test
    //
    // Vertical slice of the TTS path: synthesize a fixed sentence, write the MP3 to disk, play
    // it back. Confirms the endpoint, the model slug, the account's TTS access, and that the
    // device can decode MP3 through the swapped-in Swift 5.1.5 AVFoundation overlay.

    @objc private func testVoiceTapped() {
        save()
        guard Settings.hasAPIKey else {
            setStatus("No API key set - add one above first.")
            return
        }

        testButton.isEnabled = false
        testButton.alpha = 0.4
        testButton.setTitle("Synthesizing...", for: .normal)
        setStatus("POSTing to \(TTSAPI.endpoint)...")

        TTSAPI.synthesize(text: "Hello from cai. Text to speech is working on this device.",
                          model: Settings.ttsModel,
                          voice: Settings.ttsVoice,
                          apiKey: Settings.apiKey) { [weak self] data, error in
            guard let self = self else { return }
            self.testButton.isEnabled = true
            self.testButton.alpha = 1.0
            self.testButton.setTitle("Test Voice", for: .normal)

            if let error = error {
                self.setStatus("FAILED: " + error)
                return
            }
            guard let data = data else {
                self.setStatus("FAILED: no audio returned.")
                return
            }
            self.play(data)
        }
    }

    private func play(_ data: Data) {
        let path = NSTemporaryDirectory() + "tts_test.mp3"
        // Data.write(toFile:atomically:) doesn't exist on this runtime - go through NSData.
        guard (data as NSData).write(toFile: path, atomically: true) else {
            setStatus("FAILED: could not write \(data.count) bytes to disk.")
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            SettingsVC.testPlayer = player
            player.prepareToPlay()
            if player.play() {
                setStatus(String(format: "OK: %d bytes, %.1fs - playing.",
                                 data.count, player.duration))
            } else {
                setStatus("FAILED: player refused to start (\(data.count) bytes).")
            }
        } catch {
            setStatus("FAILED: could not decode \(data.count) bytes - \(error)")
        }
    }

    private func setStatus(_ text: String) {
        testStatusLabel.text = text
        layoutViews()
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let endValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let endInView = view.convert(endValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - endInView.minY)
        keyboardHeight = note.name == UIResponder.keyboardWillHideNotification ? 0 : overlap

        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration) {
            self.layoutViews()
        }
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        save()
        return false
    }
}
