//
//  LegacyCoreImports.swift
//  AidokuLegacy
//
//  iOS 12-compatible AidokuRunner import modules.
//

import Foundation
import SwiftSoup
import Wasm3Legacy

struct Env: SourceLibrary {
    static let namespace = "env"

    let module: Module
    let printHandler: (String) -> Void

    func link() throws {
        try? module.linkFunction(name: "abort", namespace: Self.namespace, function: abort)
        try? module.linkFunction(name: "print", namespace: Self.namespace, function: envPrint)
        try? module.linkFunction(name: "sleep", namespace: Self.namespace, function: sleep)
        try? module.linkFunction(name: "send_partial_result", namespace: Self.namespace, function: sendPartialResult)
    }

    func abort() {
        printHandler("Source aborted")
    }

    func envPrint(memory: Memory, offset: Int32, length: Int32) {
        guard offset >= 0, length >= 0 else { return }
        let string = try? memory.readString(offset: UInt32(offset), length: UInt32(length))
        printHandler(string ?? "")
    }

    func sleep(seconds: Int32) {
        Thread.sleep(forTimeInterval: TimeInterval(max(0, seconds)))
    }

    func sendPartialResult(memory _: Memory, valuePointer _: Int32) {
        // Partial streaming updates are optional for the legacy UI.
    }
}

struct Std: SourceLibrary {
    static let namespace = "std"

    let module: Module
    var store: GlobalStore

    func link() throws {
        try? module.linkFunction(name: "destroy", namespace: Self.namespace, function: destroy)
        try? module.linkFunction(name: "buffer_len", namespace: Self.namespace, function: bufferLength)
        try? module.linkFunction(name: "read_buffer", namespace: Self.namespace, function: readBuffer)
        try? module.linkFunction(name: "current_date", namespace: Self.namespace, function: currentDate)
        try? module.linkFunction(name: "utc_offset", namespace: Self.namespace, function: utcOffset)
        try? module.linkFunction(name: "parse_date", namespace: Self.namespace, function: parseDate)
    }

    enum Result: Int32 {
        case success = 0
        case invalidDescriptor = -1
        case invalidBufferSize = -2
        case failedMemoryWrite = -3
        case invalidString = -4
        case invalidDateString = -5
    }

    func destroy(descriptor: Int32) {
        store.remove(at: descriptor)
    }

    private func bytes(descriptor: Int32) -> [UInt8]? {
        let item = store.fetch(from: descriptor)
        if let data = item as? Data {
            return [UInt8](data)
        }
        if let string = item as? String {
            return [UInt8](string.utf8)
        }
        return nil
    }

    func bufferLength(descriptor: Int32) -> Int32 {
        guard let data = bytes(descriptor: descriptor) else {
            return Result.invalidDescriptor.rawValue
        }
        return Int32(data.count)
    }

    func readBuffer(_ memory: Memory, descriptor: Int32, buffer: UInt32, size: UInt32) -> Int32 {
        guard let data = bytes(descriptor: descriptor) else {
            return Result.invalidDescriptor.rawValue
        }
        guard size <= data.count else {
            return Result.invalidBufferSize.rawValue
        }
        do {
            try memory.write(bytes: Array(data.prefix(Int(size))), offset: buffer)
            return Result.success.rawValue
        } catch {
            return Result.failedMemoryWrite.rawValue
        }
    }

    func currentDate() -> Float64 {
        return Date().timeIntervalSince1970
    }

    func utcOffset() -> Int64 {
        return -Int64(TimeZone.current.secondsFromGMT())
    }

    func parseDate(
        _ memory: Memory,
        stringPtr: UInt32,
        stringLength: UInt32,
        formatPtr: UInt32,
        formatLength: UInt32,
        localePtr: UInt32,
        localeLength: UInt32,
        timeZonePtr: UInt32,
        timeZoneLength: UInt32
    ) -> Float64 {
        guard
            let string = try? memory.readString(offset: stringPtr, length: stringLength),
            let format = try? memory.readString(offset: formatPtr, length: formatLength)
        else {
            return Float64(Result.invalidString.rawValue)
        }

        let localeString = localeLength > 0 ? try? memory.readString(offset: localePtr, length: localeLength) : nil
        let timeZoneString = timeZoneLength > 0 ? try? memory.readString(offset: timeZonePtr, length: timeZoneLength) : nil

        let formatter = DateFormatter()
        if let localeString = localeString {
            formatter.locale = localeString == "current" ? Locale.current : Locale(identifier: localeString)
        }
        if let timeZoneString = timeZoneString {
            formatter.timeZone = timeZoneString == "current" ? TimeZone.current : TimeZone(identifier: timeZoneString)
        }
        formatter.dateFormat = format
        guard let date = formatter.date(from: string) else {
            return Float64(Result.invalidDateString.rawValue)
        }
        return Float64(date.timeIntervalSince1970)
    }
}

struct Defaults: SourceLibrary {
    static let namespace = "defaults"

    let module: Module
    let store: GlobalStore
    let defaultNamespace: String

    func link() throws {
        try? module.linkFunction(name: "get", namespace: Self.namespace, function: get)
        try? module.linkFunction(name: "set", namespace: Self.namespace, function: set)
    }

    enum Result: Int32 {
        case success = 0
        case invalidKey = -1
        case invalidValue = -2
        case failedEncoding = -3
        case failedDecoding = -4
    }

    enum DefaultKind: UInt8 {
        case data = 0
        case bool = 1
        case int = 2
        case float = 3
        case string = 4
        case stringArray = 5
        case null = 6
    }

    func get(memory: Memory, keyPointer: Int32, length: Int32) -> Int32 {
        guard keyPointer >= 0, length >= 0 else {
            return Result.invalidKey.rawValue
        }
        do {
            let key = try memory.readString(offset: UInt32(keyPointer), length: UInt32(length))
            let object = UserDefaults.standard.object(forKey: "\(defaultNamespace).\(key)")
            if let value = object as? Bool {
                return try store.storeEncoded(value)
            }
            if let value = object as? Int {
                return try store.storeEncoded(Int32(value))
            }
            if let value = object as? Float {
                return try store.storeEncoded(value)
            }
            if let value = object as? Double {
                return try store.storeEncoded(Float(value))
            }
            if let value = object as? String {
                return try store.storeEncoded(value)
            }
            if let value = object as? [String] {
                return try store.storeEncoded(value)
            }
            if let value = object as? Data {
                return store.store(value)
            }
            return Result.invalidValue.rawValue
        } catch {
            return Result.failedEncoding.rawValue
        }
    }

    func set(memory: Memory, keyPointer: Int32, length: Int32, valueKind: Int32, valuePointer: Int32) -> Int32 {
        guard keyPointer >= 0, length >= 0 else {
            return Result.invalidKey.rawValue
        }
        do {
            let key = try memory.readString(offset: UInt32(keyPointer), length: UInt32(length))
            guard let kind = DefaultKind(rawValue: UInt8(valueKind)) else {
                return Result.invalidValue.rawValue
            }

            func resultData() throws -> Data {
                let pointer = UInt32(valuePointer)
                let length: UInt32 = try memory.readValues(offset: pointer, length: 1)[0]
                return try memory.readData(offset: pointer + 8, length: length - 8)
            }

            let fullKey = "\(defaultNamespace).\(key)"
            switch kind {
                case .data:
                    UserDefaults.standard.set(try resultData(), forKey: fullKey)
                case .bool:
                    UserDefaults.standard.set(try PostcardDecoder().decode(Bool.self, from: resultData()), forKey: fullKey)
                case .int:
                    UserDefaults.standard.set(Int(try PostcardDecoder().decode(Int32.self, from: resultData())), forKey: fullKey)
                case .float:
                    UserDefaults.standard.set(try PostcardDecoder().decode(Float.self, from: resultData()), forKey: fullKey)
                case .string:
                    UserDefaults.standard.set(try PostcardDecoder().decode(String.self, from: resultData()), forKey: fullKey)
                case .stringArray:
                    UserDefaults.standard.set(try PostcardDecoder().decode([String].self, from: resultData()), forKey: fullKey)
                case .null:
                    UserDefaults.standard.removeObject(forKey: fullKey)
            }
            return Result.success.rawValue
        } catch {
            return Result.failedDecoding.rawValue
        }
    }
}

struct Net: SourceLibrary {
    static let namespace = "net"

    let module: Module
    let store: GlobalStore

    func link() throws {
        try? module.linkFunction(name: "init", namespace: Self.namespace, function: initialize)
        try? module.linkFunction(name: "send", namespace: Self.namespace, function: send)
        try? module.linkFunction(name: "send_all", namespace: Self.namespace, function: sendAll)
        try? module.linkFunction(name: "set_url", namespace: Self.namespace, function: setUrl)
        try? module.linkFunction(name: "set_header", namespace: Self.namespace, function: setHeader)
        try? module.linkFunction(name: "set_body", namespace: Self.namespace, function: setBody)
        try? module.linkFunction(name: "set_timeout", namespace: Self.namespace, function: setTimeout)
        try? module.linkFunction(name: "data_len", namespace: Self.namespace, function: dataLength)
        try? module.linkFunction(name: "read_data", namespace: Self.namespace, function: readData)
        try? module.linkFunction(name: "get_image", namespace: Self.namespace, function: getImage)
        try? module.linkFunction(name: "get_status_code", namespace: Self.namespace, function: getStatusCode)
        try? module.linkFunction(name: "get_url", namespace: Self.namespace, function: getUrl)
        try? module.linkFunction(name: "get_header", namespace: Self.namespace, function: getHeader)
        try? module.linkFunction(name: "html", namespace: Self.namespace, function: dataToHtml)
        try? module.linkFunction(name: "set_rate_limit", namespace: Self.namespace, function: setRateLimit)
    }

    enum Result: Int32 {
        case success = 0
        case invalidDescriptor = -1
        case invalidString = -2
        case invalidMethod = -3
        case invalidUrl = -4
        case invalidHtml = -5
        case invalidBufferSize = -6
        case missingData = -7
        case missingResponse = -8
        case missingUrl = -9
        case requestError = -10
        case failedMemoryWrite = -11
        case notAnImage = -12
    }

    func initialize(method: Int32) -> Int32 {
        guard let method = NetRequest.Method(rawValue: Int(method)) else {
            return Result.invalidMethod.rawValue
        }
        return store.store(NetRequest(method: method))
    }

    func send(descriptor: Int32) -> Int32 {
        guard var request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let urlRequest = request.toUrlRequest() else {
            return Result.missingUrl.rawValue
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: URLResponse?
        var responseError: Error?
        URLSession.shared.dataTask(with: urlRequest) { data, urlResponse, error in
            responseData = data
            response = urlResponse
            responseError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        request.responseData = responseData
        request.response = response
        request.responseError = responseError
        store.set(at: descriptor, item: request)
        return responseError == nil ? Result.success.rawValue : Result.requestError.rawValue
    }

    func sendAll(memory: Memory, descriptors: Int32, length: Int32) -> Int32 {
        guard
            descriptors >= 0,
            length > 0,
            let descriptorArray: [Int32] = try? memory.readValues(offset: UInt32(descriptors), length: UInt32(length))
        else {
            return Result.invalidDescriptor.rawValue
        }

        var errors = [Int32]()
        for descriptor in descriptorArray {
            errors.append(send(descriptor: descriptor))
        }
        try? memory.write(values: errors, offset: UInt32(descriptors))
        return errors.contains { $0 != Result.success.rawValue } ? Result.requestError.rawValue : Result.success.rawValue
    }

    func setUrl(memory: Memory, descriptor: Int32, value: Int32, length: Int32) -> Int32 {
        guard var request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard
            value >= 0,
            length > 0,
            let urlString = try? memory.readString(offset: UInt32(value), length: UInt32(length)),
            let url = URL(string: urlString)
        else {
            return Result.invalidUrl.rawValue
        }
        request.url = url
        store.set(at: descriptor, item: request)
        return Result.success.rawValue
    }

    func setHeader(memory: Memory, descriptor: Int32, key: Int32, keyLength: Int32, value: Int32, valueLength: Int32) -> Int32 {
        guard var request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard
            key >= 0,
            keyLength > 0,
            value >= 0,
            valueLength > 0,
            let keyString = try? memory.readString(offset: UInt32(key), length: UInt32(keyLength)),
            let valueString = try? memory.readString(offset: UInt32(value), length: UInt32(valueLength))
        else {
            return Result.invalidString.rawValue
        }
        request.headers[keyString] = valueString
        store.set(at: descriptor, item: request)
        return Result.success.rawValue
    }

    func setBody(memory: Memory, descriptor: Int32, value: Int32, length: Int32) -> Int32 {
        guard var request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard value >= 0, length > 0, let body = try? memory.readData(offset: UInt32(value), length: UInt32(length)) else {
            return Result.invalidString.rawValue
        }
        request.body = body
        store.set(at: descriptor, item: request)
        return Result.success.rawValue
    }

    func setTimeout(descriptor: Int32, value: Float64) -> Int32 {
        guard var request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        request.timeout = TimeInterval(value)
        store.set(at: descriptor, item: request)
        return Result.success.rawValue
    }

    func dataLength(descriptor: Int32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let data = request.responseData else {
            return Result.missingData.rawValue
        }
        return Int32(data.count)
    }

    func readData(_ memory: Memory, descriptor: Int32, buffer: UInt32, size: UInt32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let data = request.responseData else {
            return Result.missingData.rawValue
        }
        guard size <= data.count else {
            return Result.invalidBufferSize.rawValue
        }
        do {
            try memory.write(data: Data(data.prefix(Int(size))), offset: buffer)
            return Result.success.rawValue
        } catch {
            return Result.failedMemoryWrite.rawValue
        }
    }

    func getImage(descriptor _: Int32) -> Int32 {
        return Result.notAnImage.rawValue
    }

    func getStatusCode(descriptor: Int32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let response = request.response as? HTTPURLResponse else {
            return Result.missingResponse.rawValue
        }
        return Int32(response.statusCode)
    }

    func getUrl(descriptor: Int32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let url = request.response?.url?.absoluteString else {
            return Result.missingUrl.rawValue
        }
        return store.store(url)
    }

    func getHeader(memory: Memory, descriptor: Int32, key: Int32, keyLength: Int32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let response = request.response as? HTTPURLResponse else {
            return Result.missingResponse.rawValue
        }
        guard
            key >= 0,
            keyLength > 0,
            let keyString = try? memory.readString(offset: UInt32(key), length: UInt32(keyLength)),
            let value = response.value(forHTTPHeaderField: keyString)
        else {
            return Result.missingData.rawValue
        }
        return store.store(value)
    }

    func dataToHtml(descriptor: Int32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let data = request.responseData else {
            return Result.missingData.rawValue
        }
        var html = String(data: data, encoding: .utf8) ?? ""
        if html.isEmpty {
            html = String(data: data, encoding: .ascii) ?? ""
        }
        do {
            if let baseUrl = request.response?.url?.absoluteString {
                return try store.store(SwiftSoup.parse(html, baseUrl))
            }
            return try store.store(SwiftSoup.parse(html))
        } catch {
            return Result.invalidHtml.rawValue
        }
    }

    func setRateLimit(permits _: Int32, period _: Int32, unit _: Int32) {
        // Rate limiting is ignored in the legacy personal-use runner.
    }
}
