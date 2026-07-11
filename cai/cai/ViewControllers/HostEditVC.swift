import UIKit

// Add or edit a RemoteHost. Non-secret fields persist via RemoteHostStore; the
// password goes to the Keychain (keyed by host id). Presented modally with
// Cancel/Save. Manual frame layout (iOS 6 conventions).
class HostEditVC: UIViewController, UITextFieldDelegate {
    var onSave: (() -> Void)?

    private let existing: RemoteHost?
    private let scrollView = UIScrollView()

    private let labelField = UITextField()
    private let userField = UITextField()
    private let hostField = UITextField()
    private let portField = UITextField()
    private let passwordField = UITextField()

    // (caption, field) top-to-bottom.
    private var rows: [(String, UITextField)] {
        return [("Label (optional)", labelField),
                ("Username", userField),
                ("Host / IP", hostField),
                ("Port", portField),
                ("Password", passwordField)]
    }
    private var captionLabels: [UILabel] = []
    private var keyboardHeight: CGFloat = 0

    init(host: RemoteHost?) {
        self.existing = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existing == nil ? "Add Host" : "Edit Host"
        view.backgroundColor = Theme.background

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save))

        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        scrollView.backgroundColor = Theme.background
        view.addSubview(scrollView)

        labelField.placeholder = "My server"
        userField.placeholder = "root"
        hostField.placeholder = "192.168.0.101"
        portField.placeholder = "22"
        passwordField.placeholder = "••••••••"

        portField.keyboardType = .numberPad
        passwordField.isSecureTextEntry = true

        for (caption, field) in rows {
            let label = UILabel()
            label.text = caption
            label.textColor = Theme.secondaryText
            label.backgroundColor = .clear
            label.font = UIFont.boldSystemFont(ofSize: 13)
            scrollView.addSubview(label)
            captionLabels.append(label)
            styleField(field)
            scrollView.addSubview(field)
        }

        // Prefill when editing.
        if let host = existing {
            labelField.text = host.label
            userField.text = host.username
            hostField.text = host.host
            portField.text = String(host.port)
            passwordField.text = Keychain.password(for: host.id)
        }

        layoutViews()
    }

    private func styleField(_ field: UITextField) {
        field.backgroundColor = Theme.fieldBackground
        field.textColor = Theme.primaryText
        field.layer.cornerRadius = 10
        field.layer.masksToBounds = true
        field.font = UIFont.systemFont(ofSize: 16)
        field.contentVerticalAlignment = .center
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.attributedPlaceholder = NSAttributedString(
            string: field.placeholder ?? "",
            attributes: [NSAttributedString.Key.foregroundColor: Theme.secondaryText])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViews()
    }

    private func layoutViews() {
        let w = view.bounds.width
        let margin: CGFloat = 16
        let fieldW = w - 2 * margin
        let fieldH: CGFloat = 54
        var y: CGFloat = 24

        scrollView.frame = CGRect(x: 0, y: 0, width: w, height: view.bounds.height - keyboardHeight)

        for (i, pair) in rows.enumerated() {
            captionLabels[i].frame = CGRect(x: margin, y: y, width: fieldW, height: 18)
            y += 22
            pair.1.frame = CGRect(x: margin, y: y, width: fieldW, height: fieldH)
            y += fieldH + 20
        }
        scrollView.contentSize = CGSize(width: w, height: y + 8)
    }

    // MARK: - Actions

    @objc private func cancel() {
        view.endEditing(true)
        dismiss(animated: true, completion: nil)
    }

    @objc private func save() {
        view.endEditing(true)
        let user = (userField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hostAddr = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !hostAddr.isEmpty else {
            UIAlertView(title: "Missing Info", message: "Username and host are required.",
                        delegate: nil, cancelButtonTitle: "OK").show()
            return
        }
        let port = UInt16((portField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22

        let host = existing ?? RemoteHost(username: user, host: hostAddr)
        host.label = (labelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = user
        host.host = hostAddr
        host.port = port
        RemoteHostStore.shared.save(host)

        // Only overwrite the stored password when the user typed something, so editing
        // other fields without re-entering the password keeps the existing one.
        let password = passwordField.text ?? ""
        if !password.isEmpty {
            Keychain.setPassword(password, for: host.id)
        }

        onSave?()
        dismiss(animated: true, completion: nil)
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let endValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let endInView = view.convert(endValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - endInView.minY)
        keyboardHeight = note.name == UIResponder.keyboardWillHideNotification ? 0 : overlap

        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration) { self.layoutViews() }
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
}
