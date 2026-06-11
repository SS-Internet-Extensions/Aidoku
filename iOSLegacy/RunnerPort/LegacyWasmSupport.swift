//
//  LegacyWasmSupport.swift
//  AidokuLegacy
//
//  Minimal AidokuRunner support types for the iOS 12 WASM port.
//

import Foundation
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
            request.setValue(
                "Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent"
            )
        }
        return request
    }
}
