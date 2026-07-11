import UIKit
import Darwin

// In-app crash catcher. Ad-hoc-signed sideloaded builds give no easy access to the
// device crash logs, so we trap crashes ourselves, persist the reason to a sandbox
// file, and on the NEXT launch pop a debug box with a Copy button.
//
// Two crash sources are trapped:
//   1. Uncaught Obj-C exceptions (unrecognized selector etc.) via
//      NSSetUncaughtExceptionHandler — runs in a normal context, so Foundation is safe.
//   2. Fatal POSIX signals (SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP) via signal().
//      A signal handler may only call async-signal-safe functions, so that path avoids
//      Swift string/Foundation allocation: it open()s a pre-computed C path and dumps a
//      backtrace with backtrace_symbols_fd, then re-raises the default handler.
enum CrashReporter {

    private static let crashPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return (docs as NSString).appendingPathComponent(".last_crash.txt")
    }()

    // Null-terminated C copy of crashPath, computed once at install() so the signal
    // handler never has to touch Swift String / dispatch_once machinery.
    private static var pathBuffer: [CChar] = []

    // MARK: - Install

    static func install() {
        pathBuffer = crashPath.cString(using: .utf8) ?? []

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.handleException(exception)
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                CrashReporter.handleSignal(s)
            }
        }
    }

    // MARK: - Consume (call once on next launch)

    // Returns the stored crash text (and deletes it) if the previous run crashed.
    static func consumePendingCrash() -> String? {
        guard let data = FileManager.default.contents(atPath: crashPath),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(atPath: crashPath)
        return text
    }

    // MARK: - Present debug box

    private static var presentedVC: CrashReportVC?

    // Presents the debug box if a crash is pending. Deferred to the next runloop so it
    // lands after the window/root are fully up.
    static func presentIfNeeded(from root: UIViewController?) {
        guard let text = consumePendingCrash() else { return }
        DispatchQueue.main.async {
            guard let root = root else { return }
            let vc = CrashReportVC(text: text)
            presentedVC = vc
            root.present(vc, animated: true, completion: nil)
        }
    }

    // MARK: - Handlers

    private static func handleException(_ exception: NSException) {
        var lines = "=== UNCAUGHT EXCEPTION ===\n"
        lines += "Name: \(exception.name.rawValue)\n"
        lines += "Reason: \(exception.reason ?? "(nil)")\n\n"
        lines += "Call stack:\n"
        lines += exception.callStackSymbols.joined(separator: "\n")
        store(lines)
    }

    private static func store(_ text: String) {
        if let data = text.data(using: .utf8) {
            _ = (data as NSData).write(toFile: crashPath, atomically: true)
        }
    }

    // Async-signal-safe as far as practical: no Swift String building, no Foundation.
    private static func handleSignal(_ sig: Int32) {
        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frames = backtrace(&callstack, 128)

        pathBuffer.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            let fd = open(base, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                let header = signalName(sig)
                header.withUTF8Buffer { buf in
                    if let b = buf.baseAddress { _ = write(fd, b, buf.count) }
                }
                backtrace_symbols_fd(callstack, frames, fd)
                writeImageList(fd)
                close(fd)
            }
        }

        // Re-raise with the default disposition so the process still terminates.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // Dumps every loaded Mach-O image with its load address, so a "???" backtrace frame
    // (an address dladdr can't name) can be mapped to the owning dylib by hand: the image
    // whose base is the largest value <= the mystery address is the container.
    private static func writeImageList(_ fd: Int32) {
        let marker: StaticString = "\n=== IMAGES (base  path) ===\n"
        marker.withUTF8Buffer { if let b = $0.baseAddress { _ = write(fd, b, $0.count) } }

        let count = _dyld_image_count()
        var i: UInt32 = 0
        while i < count {
            if let header = _dyld_get_image_header(i),
               let name = _dyld_get_image_name(i) {
                writeHex(fd, UInt(bitPattern: header))
                _ = write(fd, "  ", 2)
                _ = write(fd, name, strlen(name))
                _ = write(fd, "\n", 1)
            }
            i += 1
        }
    }

    // Signal-context hex writer: no Foundation, fixed stack buffer.
    private static func writeHex(_ fd: Int32, _ value: UInt) {
        var buf = [UInt8](repeating: 0, count: 10)   // "0x" + 8 nibbles
        buf[0] = 0x30; buf[1] = 0x78                  // '0' 'x'
        for i in 0..<8 {
            let nyb = UInt8((value >> UInt((7 - i) * 4)) & 0xF)
            buf[2 + i] = nyb < 10 ? (0x30 + nyb) : (0x61 + (nyb - 10))
        }
        buf.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, 10) }
    }

    private static func signalName(_ sig: Int32) -> StaticString {
        switch sig {
        case SIGABRT: return "=== SIGNAL SIGABRT ===\n"
        case SIGSEGV: return "=== SIGNAL SIGSEGV ===\n"
        case SIGBUS:  return "=== SIGNAL SIGBUS ===\n"
        case SIGILL:  return "=== SIGNAL SIGILL ===\n"
        case SIGFPE:  return "=== SIGNAL SIGFPE ===\n"
        case SIGTRAP: return "=== SIGNAL SIGTRAP ===\n"
        default:      return "=== SIGNAL (other) ===\n"
        }
    }
}

// Full-screen modal showing the captured crash text in a scrollable, selectable text
// view, with a Copy button (puts the full text on the pasteboard) and a Dismiss button.
final class CrashReportVC: UIViewController {
    private let text: String
    private var toast: UILabel?

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        // viewDidLoad bounds are 0 on iOS 6 for a presented VC — use the screen.
        let screen = UIScreen.main.bounds
        let w = screen.width
        let h = screen.height
        let pad: CGFloat = 12
        let statusPad: CGFloat = 24

        let title = UILabel(frame: CGRect(x: pad, y: statusPad, width: w - pad * 2, height: 28))
        title.text = "Previous crash"
        title.textColor = Theme.primaryText
        title.backgroundColor = .clear
        title.font = UIFont.boldSystemFont(ofSize: 18)
        view.addSubview(title)

        let buttonH: CGFloat = 44
        let buttonY = h - buttonH - pad
        let buttonW = (w - pad * 3) / 2

        let textTop = statusPad + 28 + pad
        let tv = UITextView(frame: CGRect(x: pad, y: textTop,
                                          width: w - pad * 2,
                                          height: buttonY - textTop - pad))
        tv.isEditable = false
        tv.text = text
        tv.textColor = Theme.primaryText
        tv.backgroundColor = Theme.rowBackground
        tv.font = UIFont(name: "Menlo", size: 11) ?? UIFont.systemFont(ofSize: 11)
        view.addSubview(tv)

        let copyBtn = UIButton(type: .custom)
        copyBtn.frame = CGRect(x: pad, y: buttonY, width: buttonW, height: buttonH)
        copyBtn.setTitle("Copy", for: .normal)
        copyBtn.setTitleColor(.white, for: .normal)
        copyBtn.backgroundColor = Theme.accent
        copyBtn.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        view.addSubview(copyBtn)

        let dismissBtn = UIButton(type: .custom)
        dismissBtn.frame = CGRect(x: pad * 2 + buttonW, y: buttonY, width: buttonW, height: buttonH)
        dismissBtn.setTitle("Dismiss", for: .normal)
        dismissBtn.setTitleColor(.white, for: .normal)
        dismissBtn.backgroundColor = Theme.fieldBackground
        dismissBtn.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(dismissBtn)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = text
        showToast("Copied to clipboard")
    }

    @objc private func dismissTapped() {
        dismiss(animated: true, completion: nil)
    }

    private func showToast(_ message: String) {
        toast?.removeFromSuperview()
        let screen = UIScreen.main.bounds
        let label = UILabel(frame: CGRect(x: 40, y: screen.height / 2 - 20,
                                          width: screen.width - 80, height: 40))
        label.text = message
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.8)
        label.layer.cornerRadius = 8
        label.font = UIFont.systemFont(ofSize: 15)
        view.addSubview(label)
        toast = label
        // Hide after ~1.2s (target/selector form — block timers are iOS 10+).
        let t = Timer(timeInterval: 1.2, target: self,
                      selector: #selector(hideToast), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    @objc private func hideToast() {
        toast?.removeFromSuperview()
        toast = nil
    }
}
