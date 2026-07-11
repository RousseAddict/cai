import Foundation
import Darwin

// Synchronous libssh2 wrapper: TCP connect -> handshake -> password auth -> exec.
// All calls BLOCK, so callers must run them off the main thread (a serial
// background queue per host). libssh2's public API is largely C macros that the
// Swift importer drops, so we call the underlying *_ex / *_startup functions and
// re-declare the macro constants (window/packet sizes, disconnect reason) here.
enum SSHError: Error, CustomStringConvertible {
    case socket(String)
    case handshake(String)
    case auth(String)
    case channel(String)
    case notConnected

    var description: String {
        switch self {
        case .socket(let m):    return "Connection failed: \(m)"
        case .handshake(let m): return "SSH handshake failed: \(m)"
        case .auth(let m):      return "Authentication failed: \(m)"
        case .channel(let m):   return "Command failed: \(m)"
        case .notConnected:     return "Not connected"
        }
    }
}

final class SSHClient {

    private var session: OpaquePointer?
    private var sock: Int32 = -1

    // libssh2_init must run once per process before any session is created.
    private static let initOnce: Int32 = libssh2_init(0)

    // Macro constants from libssh2.h (not importable into Swift).
    private static let channelWindowDefault: UInt32 = 2 * 1024 * 1024
    private static let channelPacketDefault: UInt32 = 32768
    private static let disconnectByApplication: Int32 = 11   // SSH_DISCONNECT_BY_APPLICATION

    var isConnected: Bool { return session != nil }

    // MARK: - Lifecycle

    // Blocking. Opens the socket, runs the SSH handshake, authenticates by password.
    func connect(host: String, port: UInt16 = 22, username: String, password: String) throws {
        _ = SSHClient.initOnce

        sock = try SSHClient.openSocket(host: host, port: port)

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            closeSocket()
            throw SSHError.handshake("could not create session")
        }
        self.session = session
        libssh2_session_set_blocking(session, 1)

        // curve25519 KEX takes OpenSSL's raw-key/EVP (X25519) path, which traps on
        // armv7/iOS 6 (SIGTRAP in curve25519_sha256 mid-handshake). Steer negotiation
        // toward classic KEX methods so libssh2 never enters that code path.
        // LIBSSH2_METHOD_KEX == 0 (the macro is dropped by the Swift importer).
        let kexPrefs = "diffie-hellman-group14-sha256,diffie-hellman-group14-sha1," +
                       "ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256"
        _ = kexPrefs.withCString { libssh2_session_method_pref(session, 0, $0) }

        let hrc = libssh2_session_handshake(session, sock)
        if hrc != 0 {
            let msg = lastError() ?? "handshake error \(hrc)"
            teardown()
            throw SSHError.handshake(msg)
        }

        let userLen = UInt32(username.utf8.count)
        let passLen = UInt32(password.utf8.count)
        let arc = username.withCString { u in
            password.withCString { p in
                libssh2_userauth_password_ex(session, u, userLen, p, passLen, nil)
            }
        }
        if arc != 0 {
            let msg = lastError() ?? "auth error \(arc)"
            teardown()
            throw SSHError.auth(msg)
        }
    }

    func disconnect() { teardown() }

    deinit { teardown() }

    // MARK: - Command execution

    // Blocking. Runs `command` in a fresh channel and returns its combined output.
    func execute(_ command: String) throws -> String {
        guard let session = session else { throw SSHError.notConnected }

        guard let channel = libssh2_channel_open_ex(
            session, "session", 7,
            SSHClient.channelWindowDefault, SSHClient.channelPacketDefault, nil, 0
        ) else {
            throw SSHError.channel(lastError() ?? "could not open channel")
        }
        defer {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
        }

        let src = command.withCString {
            libssh2_channel_process_startup(channel, "exec", 4, $0, UInt32(command.utf8.count))
        }
        if src != 0 {
            throw SSHError.channel(lastError() ?? "exec failed \(src)")
        }

        var output = Data()
        var buffer = [Int8](repeating: 0, count: 8192)
        while true {
            let n = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if n > 0 {
                buffer.withUnsafeBytes { raw in
                    output.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: Int(n))
                }
            } else {
                // 0 = EOF; negative = error (treated as end of stream in blocking mode).
                break
            }
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    // MARK: - Private

    private func teardown() {
        if let session = session {
            libssh2_session_disconnect_ex(session, SSHClient.disconnectByApplication, "bye", "")
            libssh2_session_free(session)
            self.session = nil
        }
        closeSocket()
    }

    private func closeSocket() {
        if sock >= 0 { close(sock); sock = -1 }
    }

    private func lastError() -> String? {
        guard let session = session else { return nil }
        var msgPtr: UnsafeMutablePointer<CChar>? = nil
        var len: Int32 = 0
        // want_buf = 0: libssh2 returns a pointer to its own storage (do not free).
        let code = libssh2_session_last_error(session, &msgPtr, &len, 0)
        if let msgPtr = msgPtr {
            return "\(String(cString: msgPtr)) (\(code))"
        }
        return "error \(code)"
    }

    // Resolves `host` and connects, with a bounded connect timeout and read/write
    // timeouts so a dead host can't wedge the background thread indefinitely.
    private static func openSocket(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>? = nil
        let gai = getaddrinfo(host, String(port), &hints, &result)
        if gai != 0 {
            throw SSHError.socket(String(cString: gai_strerror(gai)))
        }
        defer { if let result = result { freeaddrinfo(result) } }

        var node = result
        while let a = node {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd: fd, addr: a.pointee.ai_addr, len: a.pointee.ai_addrlen, seconds: 10) {
                    var tv = timeval(tv_sec: 20, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    return fd
                }
                close(fd)
            }
            node = a.pointee.ai_next
        }
        throw SSHError.socket("could not connect to \(host):\(port)")
    }

    // Non-blocking connect + poll(POLLOUT) so we can enforce a timeout, then
    // restore blocking mode for libssh2.
    private static func connectWithTimeout(fd: Int32, addr: UnsafeMutablePointer<sockaddr>?, len: socklen_t, seconds: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = Darwin.connect(fd, addr, len)
        if rc != 0 && errno != EINPROGRESS {
            return false
        }

        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, seconds * 1000)
            if pr <= 0 { return false }   // timeout or error

            var soError: Int32 = 0
            var l = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &l)
            if soError != 0 { return false }
        }

        _ = fcntl(fd, F_SETFL, flags)   // back to blocking
        return true
    }
}

// Runs blocking SSH work on a dedicated thread with a large stack. The SSH handshake
// (OpenSSL key exchange / modular exponentiation) is stack-heavy and overflows the
// default ~512KB secondary/GCD-worker thread stack, crashing mid-handshake. 2MB is
// comfortable. Thread(block:) is iOS 10+, so we subclass and override main() (iOS 2+).
final class SSHWorkThread: Thread {
    private let work: () -> Void

    init(work: @escaping () -> Void) {
        self.work = work
        super.init()
        self.stackSize = 2 * 1024 * 1024
    }

    override func main() {
        work()
    }
}
