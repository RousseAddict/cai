import Foundation

// MARK: - C-compatible callbacks (file scope)

private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    Unmanaged<NSMutableData>.fromOpaque(userdata).takeUnretainedValue().append(ptr, length: bytes)
    return bytes
}

// Streaming write callback. Forwards each received chunk to the box's handler AND accumulates
// the full body (so a non-200 error body can be read after the transfer completes). onBytes runs
// on the curl worker thread — the caller is responsible for hopping to main as needed.
private let curlStreamWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlStreamBox>.fromOpaque(userdata).takeUnretainedValue()
    let chunk = Data(bytes: ptr, count: bytes)
    box.accumulated.append(chunk)
    box.onBytes(chunk)
    return bytes
}

private let curlFileWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(userdata).takeUnretainedValue()
    box.fileHandle?.write(Data(bytes: ptr, count: bytes))
    box.bytesReceived += Int64(bytes)
    return bytes
}

private let curlProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, dltotal, dlnow, _, _ in
    guard let clientp = clientp, dltotal > 0 else { return 0 }
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(clientp).takeUnretainedValue()
    let progress = Float(dlnow) / Float(dltotal)
    DispatchQueue.main.async { box.progressHandler?(progress) }
    return 0
}

private class CurlDownloadBox {
    var fileHandle: FileHandle?
    var bytesReceived: Int64 = 0
    var progressHandler: ((Float) -> Void)?
}

private class CurlStreamBox {
    let onBytes: (Data) -> Void
    let accumulated = NSMutableData()
    init(_ onBytes: @escaping (Data) -> Void) { self.onBytes = onBytes }
}

// MARK: - CurlFetcher

class CurlFetcher {
    // Neutral user-agent for API calls (was a YouTube client string in the old app).
    static let defaultUserAgent = "cai/1.0 (iOS)"

    private static var active: [CurlFetcher] = []

    // Concurrent worker queue (no QoS — DispatchQoS is iOS 8+; this app targets iOS 6/7).
    private static let curlQueue = DispatchQueue(label: "com.cai.curl", attributes: .concurrent)
    // Serial gate: holds back dispatch to curlQueue until a slot frees, so we never spawn
    // a worker thread per queued request (iPhone 4S has a hard thread/stack-memory budget).
    private static let gateQueue = DispatchQueue(label: "com.cai.curl.gate")
    // Caps concurrent in-flight transfers. A live SSE chat stream occupies one slot for its
    // whole duration, so keep room for speech synthesis plus one other request alongside it.
    private static let curlLimit = DispatchSemaphore(value: 3)
    // dispatch_once via static let — runs exactly once even under concurrent first access
    // (Swift lazy-static init is thread-safe), so curl_global_init is never called concurrently.
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    private static func submit(_ work: @escaping () -> Void) {
        gateQueue.async {
            curlLimit.wait()
            curlQueue.async {
                work()
                curlLimit.signal()
            }
        }
    }

    // MARK: - Public API

    // GET request
    static func fetchData(url: String, timeout: Int = 30, completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit {
            let data = fetcher.syncFetchData(url: url, timeout: timeout)
            DispatchQueue.main.async { release(fetcher); completion(data) }
        }
    }

    // POST JSON request. completion delivers the HTTP status code and the response body
    // (body is returned regardless of status so callers can surface error payloads).
    static func postJSON(url: String,
                         body: String,
                         headers: [String],
                         userAgent: String = defaultUserAgent,
                         timeout: Int = 30,
                         completion: @escaping (Int, Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit {
            let (code, data) = fetcher.syncPostJSON(url: url, body: body, headers: headers,
                                                    userAgent: userAgent, timeout: timeout)
            DispatchQueue.main.async { release(fetcher); completion(code, data) }
        }
    }

    // Streaming POST JSON (e.g. SSE). onChunk fires on a background thread with each received
    // slice of the body as it arrives. completion delivers the final HTTP status and the full
    // accumulated body (both on the main thread) when the transfer finishes.
    static func postJSONStream(url: String,
                               body: String,
                               headers: [String],
                               userAgent: String = defaultUserAgent,
                               timeout: Int = 120,
                               onChunk: @escaping (Data) -> Void,
                               completion: @escaping (Int, Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit {
            let (code, data) = fetcher.syncPostJSONStream(url: url, body: body, headers: headers,
                                                          userAgent: userAgent, timeout: timeout,
                                                          onChunk: onChunk)
            DispatchQueue.main.async { release(fetcher); completion(code, data) }
        }
    }

    // File download with progress
    static func downloadToFile(url: String,
                               outputPath: String,
                               progress: ((Float) -> Void)?,
                               completion: @escaping (Bool) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit {
            let ok = fetcher.syncDownload(url: url, outputPath: outputPath, progress: progress)
            DispatchQueue.main.async { release(fetcher); completion(ok) }
        }
    }

    // MARK: - Lifecycle

    private static func retain(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self); active.append(f); objc_sync_exit(CurlFetcher.self)
    }
    private static func release(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self); active.removeAll { $0 === f }; objc_sync_exit(CurlFetcher.self)
    }

    // MARK: - Sync implementations

    private func syncFetchData(url: String, timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)
        guard curl_bridge_perform(h) == 0 else { return nil }
        guard curl_bridge_response_code(h) == 200 else { return nil }
        return buf as Data
    }

    private func configurePost(_ h: CurlHandle?, url: String, body: String, headers: [String],
                               userAgent: String, timeout: Int) {
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        for header in headers { header.withCString { curl_bridge_add_header(h, $0) } }
        userAgent.withCString { curl_bridge_set_useragent(h, $0) }
        // Pass body as a C string with explicit length (avoids null-terminator issues)
        let bodyData = Array(body.utf8)
        bodyData.withUnsafeBytes { rawBuf in
            let cptr = rawBuf.baseAddress!.assumingMemoryBound(to: Int8.self)
            curl_bridge_set_post_body(h, cptr, CLong(bodyData.count))
        }
    }

    private func syncPostJSON(url: String, body: String, headers: [String],
                              userAgent: String, timeout: Int) -> (Int, Data?) {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()
        configurePost(h, url: url, body: body, headers: headers, userAgent: userAgent, timeout: timeout)
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)
        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return (0, nil) }
        return (Int(curl_bridge_response_code(h)), buf as Data)
    }

    private func syncPostJSONStream(url: String, body: String, headers: [String],
                                    userAgent: String, timeout: Int,
                                    onChunk: @escaping (Data) -> Void) -> (Int, Data?) {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        let box = CurlStreamBox(onChunk)
        let ptr = Unmanaged.passUnretained(box).toOpaque()
        configurePost(h, url: url, body: body, headers: headers, userAgent: userAgent, timeout: timeout)
        curl_bridge_set_write_fn(h, curlStreamWriteCallback, ptr)
        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return (0, box.accumulated as Data) }
        return (Int(curl_bridge_response_code(h)), box.accumulated as Data)
    }

    private func syncDownload(url: String, outputPath: String, progress: ((Float) -> Void)?) -> Bool {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
        guard let fh = FileHandle(forWritingAtPath: outputPath) else { return false }
        let box = CurlDownloadBox(); box.fileHandle = fh; box.progressHandler = progress
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 600)
        curl_bridge_set_write_fn(h, curlFileWriteCallback, boxPtr)
        if progress != nil { curl_bridge_set_progress_fn(h, curlProgressCallback, boxPtr) }
        let rc = curl_bridge_perform(h)
        fh.closeFile()
        guard rc == 0 else { try? FileManager.default.removeItem(atPath: outputPath); return false }
        let code = curl_bridge_response_code(h)
        guard code == 200 || code == 206 else {
            try? FileManager.default.removeItem(atPath: outputPath); return false
        }
        return box.bytesReceived > 0
    }
}
