//
//  LegacyWasmSupport.swift
//  AidokuLegacy
//
//  Minimal AidokuRunner support types for the iOS 12 WASM port.
//

import Foundation
import OpenSSL
import Security
import UIKit
import Wasm3Legacy

protocol SourceLibrary {
    func link() throws
}

enum SourceError: LocalizedError, Equatable {
    case missingResult
    case unimplemented
    case networkError
    case message(String)

    var errorDescription: String? {
        switch self {
            case .missingResult:
                return "The source did not return a result."
            case .unimplemented:
                return "The source does not implement this operation."
            case .networkError:
                return "The source request failed."
            case .message(let message):
                return message
        }
    }
}

/// Records the most recent failed/abnormal network response so the generic
/// "source request failed" error can report a concrete reason (HTTP status,
/// TLS/DNS error, etc.) for diagnosis on devices without a console.
final class LegacyNetDiagnostics {
    static let shared = LegacyNetDiagnostics()
    private let lock = NSLock()
    private var _lastFailure: String?

    var lastFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastFailure
    }

    func record(_ message: String) {
        lock.lock(); _lastFailure = message; lock.unlock()
        NSLog("[AidokuLegacy] net: %@", message)
    }
}

/// Lets the iOS 12 networking stack reach servers whose certificate chains use
/// roots newer than the device trust store. MangaDex (and any Let's Encrypt site
/// on the new ISRG Root X2 / shortlived hierarchy) chains to roots iOS 12 never
/// shipped, so `URLSession` aborts the TLS handshake with NSURLErrorDomain -1200.
/// We run the normal system trust evaluation first and only accept the presented
/// chain when that fails, so well-trusted servers behave exactly as before.
final class LegacyTLSCompatDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // System trust store lacks the chain's root; accept the presented
            // chain so legacy devices can still reach modern TLS endpoints.
            NSLog("[AidokuLegacy] net: accepted untrusted chain for %@", challenge.protectionSpace.host)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }
}

enum LegacyURLSession {
    /// Shared session that tolerates certificate roots missing from the iOS 12
    /// trust store. Use this instead of `URLSession.shared` for source requests.
    static let shared: URLSession = URLSession(
        configuration: .default,
        delegate: LegacyTLSCompatDelegate(),
        delegateQueue: nil
    )
}

/// Tracks hosts that require a TLS version newer than iOS 12's `URLSession` can
/// negotiate. MangaDex is now TLS 1.3-only, which iOS 12's Secure Transport
/// (capped at TLS 1.2) cannot speak, so the handshake aborts before the trust
/// delegate ever runs. Requests to these hosts go through `LegacyHTTPSClient`.
final class LegacyTLS13Hosts {
    static let shared = LegacyTLS13Hosts()

    private let lock = NSLock()
    private var hosts: Set<String> = [
        "api.mangadex.org",
        "uploads.mangadex.org",
        "mangadex.org",
    ]

    func contains(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        lock.lock(); defer { lock.unlock() }
        return hosts.contains(host)
    }

    func add(_ host: String?) {
        guard let host = host?.lowercased() else { return }
        lock.lock(); hosts.insert(host); lock.unlock()
    }
}

/// Minimal blocking HTTPS client built on OpenSSL so iOS 12 can reach servers
/// that only speak TLS 1.3. iOS 12's `URLSession`/Secure Transport caps at TLS
/// 1.2, so such servers abort the handshake with NSURLErrorDomain -1200 before
/// the trust delegate runs. OpenSSL negotiates TLS 1.3 in user space over a raw
/// socket, also sidestepping App Transport Security.
///
/// Certificate chains are intentionally not verified — matching the existing
/// `LegacyTLSCompatDelegate`, which already accepts roots missing from the iOS 12
/// trust store. OpenSSL 3's client default does not require peer verification,
/// so an untrusted chain does not abort the handshake.
enum LegacyHTTPSClient {
    private static let errorDomain = "LegacyHTTPSClient"
    private static let maxRedirects = 5
    private static let maxResponseBytes = 64 * 1024 * 1024

    /// Shared TLS context; OpenSSL 3's `TLS_client_method` negotiates TLS 1.2/1.3.
    private static let context: OpaquePointer? = {
        guard let method = TLS_client_method() else { return nil }
        return SSL_CTX_new(method)
    }()

    /// Performs `request` synchronously, returning a `URLSession`-style tuple.
    static func send(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        guard let url = request.url else {
            return (nil, nil, makeError("missing url"))
        }
        let method = request.httpMethod ?? "GET"
        var headers = request.allHTTPHeaderFields ?? [:]
        // We manage these ourselves; drop any source-supplied copies.
        for key in [
            "Host", "host", "Connection", "connection",
            "Content-Length", "content-length", "Accept-Encoding", "accept-encoding",
        ] {
            headers.removeValue(forKey: key)
        }
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30

        do {
            let (data, response) = try perform(
                url: url,
                method: method,
                headers: headers,
                body: request.httpBody,
                timeout: timeout,
                redirectsLeft: maxRedirects
            )
            return (data, response, nil)
        } catch {
            return (nil, nil, error)
        }
    }

    private static func perform(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        redirectsLeft: Int
    ) throws -> (Data, URLResponse) {
        guard url.scheme?.lowercased() == "https", let host = url.host else {
            throw makeError("unsupported url \(url.absoluteString)")
        }
        let port = url.port ?? 443
        let (status, responseHeaders, responseBody) = try roundTrip(
            host: host, port: port, url: url,
            method: method, headers: headers, body: body, timeout: timeout
        )

        if (300...399).contains(status),
           let location = headerValue(responseHeaders, "Location"),
           let nextURL = URL(string: location, relativeTo: url)?.absoluteURL,
           nextURL.scheme?.lowercased() == "https",
           redirectsLeft > 0 {
            let nextMethod: String
            let nextBody: Data?
            if status == 307 || status == 308 {
                nextMethod = method
                nextBody = body
            } else {
                nextMethod = method == "HEAD" ? "HEAD" : "GET"
                nextBody = nil
            }
            return try perform(
                url: nextURL, method: nextMethod, headers: headers,
                body: nextBody, timeout: timeout, redirectsLeft: redirectsLeft - 1
            )
        }

        // Record the final response shape so a downstream "did not return a
        // result" (the source parsed but produced nothing) names a concrete
        // reason — non-2xx status, empty body, or unexpected content-encoding.
        let encoding = headerValue(responseHeaders, "Content-Encoding") ?? "identity"
        let contentType = headerValue(responseHeaders, "Content-Type") ?? "?"
        LegacyNetDiagnostics.shared.record(
            "\(host) via OpenSSL — HTTP \(status), \(responseBody.count) bytes, enc=\(encoding), type=\(contentType)"
        )
        return (responseBody, makeResponse(url: url, status: status, headers: responseHeaders))
    }

    private static func roundTrip(
        host: String,
        port: Int,
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) throws -> (Int, [String: String], Data) {
        let fd = try connectSocket(host: host, port: port, timeout: timeout)
        defer { close(fd) }

        guard let ctx = context, let ssl = SSL_new(ctx) else {
            throw makeError("TLS context unavailable for \(host)")
        }
        defer { SSL_free(ssl) }
        _ = SSL_set_fd(ssl, fd)
        // Server Name Indication (required by modern multi-tenant hosts).
        // 55 = SSL_CTRL_SET_TLSEXT_HOSTNAME, 0 = TLSEXT_NAMETYPE_host_name.
        host.withCString { cHost in
            _ = SSL_ctrl(ssl, 55, 0, UnsafeMutableRawPointer(mutating: cHost))
        }
        let handshake = SSL_connect(ssl)
        if handshake != 1 {
            throw makeError("TLS handshake failed for \(host) (ssl error \(SSL_get_error(ssl, handshake)))")
        }

        let requestData = buildRequest(
            url: url, host: host, port: port, method: method, headers: headers, body: body
        )
        try requestData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let written = SSL_write(ssl, base + offset, Int32(min(total - offset, Int(Int32.max))))
                if written <= 0 {
                    throw makeError("TLS write failed for \(host)")
                }
                offset += Int(written)
            }
        }

        // The request sends `Connection: close`, so read until the server closes.
        var response = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let read = SSL_read(ssl, &buffer, Int32(bufferSize))
            if read > 0 {
                response.append(buffer, count: Int(read))
                if response.count > maxResponseBytes {
                    throw makeError("response too large from \(host)")
                }
            } else {
                break
            }
        }
        _ = SSL_shutdown(ssl)

        return try parseResponse(response, host: host)
    }

    private static func connectSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, info != nil else {
            throw makeError("DNS lookup failed for \(host)")
        }
        defer { freeaddrinfo(info) }

        var node = info
        while let addr = node {
            let ai = addr.pointee
            let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd: fd, addr: ai.ai_addr, len: ai.ai_addrlen, timeout: timeout) {
                    configureSocket(fd, timeout: timeout)
                    return fd
                }
                close(fd)
            }
            node = ai.ai_next
        }
        throw makeError("could not connect to \(host)")
    }

    private static func connectWithTimeout(
        fd: Int32,
        addr: UnsafeMutablePointer<sockaddr>?,
        len: socklen_t,
        timeout: TimeInterval
    ) -> Bool {
        guard let addr = addr else { return false }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }  // restore blocking

        let result = connect(fd, addr, len)
        if result == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(clamping: max(1, Int(timeout * 1000)))
        guard poll(&pfd, 1, ms) > 0 else { return false }

        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        return soError == 0
    }

    private static func configureSocket(_ fd: Int32, timeout: TimeInterval) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func buildRequest(
        url: URL,
        host: String,
        port: Int,
        method: String,
        headers: [String: String],
        body: Data?
    ) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?" + query
        }
        let hostHeader = port == 443 ? host : "\(host):\(port)"

        var head = "\(method) \(target) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Accept-Encoding: identity\r\n"
        head += "Connection: close\r\n"
        if let body = body, !body.isEmpty {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if let body = body {
            data.append(body)
        }
        return data
    }

    private static func parseResponse(_ data: Data, host: String) throws -> (Int, [String: String], Data) {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])  // CRLF CRLF
        guard let range = data.range(of: separator) else {
            throw makeError("malformed response from \(host)")
        }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        var bodyData = data.subdata(in: range.upperBound..<data.endIndex)

        var lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw makeError("missing status line from \(host)")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw makeError("unparseable status from \(host): \(statusLine)")
        }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[key] {
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }

        if let encoding = headerValue(headers, "Transfer-Encoding"), encoding.lowercased().contains("chunked") {
            bodyData = dechunk(bodyData)
        }
        return (status, headers, bodyData)
    }

    private static func dechunk(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data([0x0D, 0x0A])
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeText = String(decoding: data.subdata(in: index..<lineEnd.lowerBound), as: UTF8.self)
            let sizeToken = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else {
                break
            }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            output.append(data.subdata(in: chunkStart..<chunkEnd))
            index = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return output
    }

    private static func makeResponse(url: URL, status: Int, headers: [String: String]) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }

    private static func headerValue(_ headers: [String: String], _ name: String) -> String? {
        let lowerName = name.lowercased()
        return headers.first { $0.key.lowercased() == lowerName }?.value
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: errorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Routes a source HTTP request through iOS 12's `URLSession` when possible,
/// falling back to `LegacyHTTPSClient` for hosts that require TLS 1.3. A host
/// that fails with a secure-connection error is remembered so later requests go
/// straight to the OpenSSL path.
func legacyPerformSourceRequest(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
    let host = request.url?.host
    let isHTTPS = request.url?.scheme?.lowercased() == "https"

    if isHTTPS, LegacyTLS13Hosts.shared.contains(host) {
        return LegacyHTTPSClient.send(request)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var response: URLResponse?
    var responseError: Error?
    LegacyURLSession.shared.dataTask(with: request) { data, urlResponse, error in
        responseData = data
        response = urlResponse
        responseError = error
        semaphore.signal()
    }.resume()
    semaphore.wait()

    if isHTTPS, let nsError = responseError as NSError?,
       nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorSecureConnectionFailed {
        // iOS 12 likely can't negotiate this host's TLS version; remember it and
        // retry over OpenSSL.
        LegacyTLS13Hosts.shared.add(host)
        LegacyNetDiagnostics.shared.record(
            "\(request.url?.absoluteString ?? "?") — retrying over OpenSSL after TLS failure"
        )
        return LegacyHTTPSClient.send(request)
    }

    return (responseData, response, responseError)
}

final class GlobalStore {
    private var storage: [Int32: Any] = [:]
    private var pointer: Int32 = 1

    func store(_ item: Any) -> Int32 {
        let descriptor = pointer
        storage[descriptor] = item
        pointer += 1
        return descriptor
    }

    func storeEncoded<T: Codable>(_ item: T) throws -> Int32 {
        return try store(PostcardEncoder().encode(item))
    }

    func storeOptionalEncoded<T: Codable>(_ item: T?) throws -> Int32 {
        guard let item = item else { return -1 }
        return try store(PostcardEncoder().encode(item))
    }

    func fetch(from descriptor: Int32) -> Any? {
        return storage[descriptor]
    }

    func fetchImage(from descriptor: Int32) -> UIImage? {
        if let image = fetch(from: descriptor) as? UIImage {
            return image
        }
        if let data = fetch(from: descriptor) as? Data {
            return UIImage(data: data)
        }
        return nil
    }

    func set(at descriptor: Int32, item: Any) {
        storage[descriptor] = item
    }

    func remove(at descriptor: Int32) {
        storage.removeValue(forKey: descriptor)
        if storage.isEmpty {
            pointer = 1
        }
    }
}

final class LegacyPartialResultHandler {
    typealias Callback = (Any?, Data) -> Any?

    private var callbacks: [UUID: Callback] = [:]
    private var storage: [UUID: Any] = [:]

    func register(_ callback: @escaping Callback) -> UUID {
        let id = UUID()
        callbacks[id] = callback
        return id
    }

    func remove(id: UUID) {
        callbacks.removeValue(forKey: id)
        storage.removeValue(forKey: id)
    }

    func data(for id: UUID) -> Any? {
        return storage[id]
    }

    func trigger(with data: Data) {
        for (id, callback) in callbacks {
            if let result = callback(storage[id], data) {
                storage[id] = result
            } else {
                storage.removeValue(forKey: id)
            }
        }
    }
}

struct NetRequest {
    enum Method: Int {
        case get = 0
        case post
        case put
        case head
        case delete
        case patch
        case options
        case connect
        case trace

        var stringValue: String {
            switch self {
                case .get: return "GET"
                case .post: return "POST"
                case .put: return "PUT"
                case .head: return "HEAD"
                case .delete: return "DELETE"
                case .patch: return "PATCH"
                case .options: return "OPTIONS"
                case .connect: return "CONNECT"
                case .trace: return "TRACE"
            }
        }
    }

    let method: Method
    var url: URL?
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval?

    var response: URLResponse?
    var responseData: Data?
    var responseError: Error?

    init(method: Method, url: URL? = nil) {
        self.method = method
        self.url = url
    }

    func toUrlRequest() -> URLRequest? {
        guard let url = url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method.stringValue
        request.httpBody = body
        request.timeoutInterval = timeout ?? 30
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            // MangaDex's API rejects browser-style `Mozilla/...` user agents with a
            // branded HTML 400 (an anti-scraping measure: it requires a unique,
            // identifying, non-browser UA). A spoofed Safari UA here therefore
            // breaks every MangaDex request, so identify as the app instead. Any
            // non-browser token is accepted (verified: `Aidoku/x` -> 200). Sources
            // that genuinely need a browser UA to clear a Cloudflare JS challenge
            // set one themselves or run through the web view path, which keeps its
            // browser UA.
            let appVersion = Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
            request.setValue(
                "Aidoku/\(appVersion) (iOS 12)",
                forHTTPHeaderField: "User-Agent"
            )
        }
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.cookies(for: url) ?? [])
        for (key, value) in cookieHeaders {
            if key == "Cookie", let existing = request.value(forHTTPHeaderField: "Cookie"), !existing.isEmpty {
                request.setValue(value + "; " + existing, forHTTPHeaderField: key)
            } else {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }
}
