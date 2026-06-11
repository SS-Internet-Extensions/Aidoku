//
//  LegacyCoreImports.swift
//  AidokuLegacy
//
//  iOS 12-compatible AidokuRunner import modules.
//

import Foundation
import JavaScriptCore
import SwiftSoup
import WebKit
import Wasm3Legacy

struct Env: SourceLibrary {
    static let namespace = "env"

    let module: Module
    let partialResultHandler: LegacyPartialResultHandler?
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

    func sendPartialResult(memory: Memory, valuePointer: Int32) {
        guard
            valuePointer >= 0,
            case let pointer = UInt32(valuePointer),
            let length: UInt32 = try? memory.readValues(offset: pointer, length: 1)[0],
            let data = try? memory.readData(offset: pointer + 8, length: length + 8)
        else {
            return
        }
        partialResultHandler?.trigger(with: data)
    }
}

struct Std: SourceLibrary {
    static let namespace = "std"

    let module: Module
    var store: GlobalStore
    let printHandler: ((String) -> Void)?

    func link() throws {
        try? module.linkFunction(name: "abort", namespace: Self.namespace, function: abort)
        try? module.linkFunction(name: "print", namespace: Self.namespace, function: stdPrint)
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

    func abort() {
        printHandler?("Source aborted")
    }

    func stdPrint(memory: Memory, offset: Int32, length: Int32) {
        guard offset >= 0, length >= 0 else { return }
        let string = try? memory.readString(offset: UInt32(offset), length: UInt32(length))
        printHandler?(string ?? "")
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

struct JavaScript: SourceLibrary {
    static let namespace = "js"

    let module: Module
    let store: GlobalStore

    func link() throws {
        try? module.linkFunction(name: "context_create", namespace: Self.namespace, function: contextCreate)
        try? module.linkFunction(name: "context_eval", namespace: Self.namespace, function: contextEval)
        try? module.linkFunction(name: "context_get", namespace: Self.namespace, function: contextGet)
        try? module.linkFunction(name: "webview_create", namespace: Self.namespace, function: webViewCreate)
        try? module.linkFunction(name: "webview_load", namespace: Self.namespace, function: webViewLoad)
        try? module.linkFunction(name: "webview_load_html", namespace: Self.namespace, function: webViewLoadHtml)
        try? module.linkFunction(name: "webview_wait_for_load", namespace: Self.namespace, function: webViewWaitForLoad)
        try? module.linkFunction(name: "webview_eval", namespace: Self.namespace, function: webViewEval)
    }

    enum Result: Int32 {
        case success = 0
        case missingResult = -1
        case invalidContext = -2
        case invalidString = -3
        case invalidHandler = -4
        case invalidRequest = -5
    }

    func contextCreate() -> Int32 {
        guard let context = JSContext() else {
            return Result.missingResult.rawValue
        }
        return store.store(context)
    }

    func contextEval(memory: Memory, descriptor: Int32, stringPointer: Int32, length: Int32) -> Int32 {
        guard let context = store.fetch(from: descriptor) as? JSContext else {
            return Result.invalidContext.rawValue
        }
        guard
            stringPointer >= 0,
            length > 0,
            let jsString = try? memory.readString(offset: UInt32(stringPointer), length: UInt32(length))
        else {
            return Result.invalidString.rawValue
        }
        guard let result = context.evaluateScript(jsString)?.toString() else {
            return Result.missingResult.rawValue
        }
        return store.store(result)
    }

    func contextGet(memory: Memory, descriptor: Int32, stringPointer: Int32, length: Int32) -> Int32 {
        guard let context = store.fetch(from: descriptor) as? JSContext else {
            return Result.invalidContext.rawValue
        }
        guard
            stringPointer >= 0,
            length > 0,
            let jsString = try? memory.readString(offset: UInt32(stringPointer), length: UInt32(length))
        else {
            return Result.invalidString.rawValue
        }
        guard let result = context.objectForKeyedSubscript(jsString)?.toString() else {
            return Result.missingResult.rawValue
        }
        return store.store(result)
    }

    func webViewCreate() -> Int32 {
        let handler = aidokuLegacyRunOnMainThread {
            LegacyWasmWebViewHandler(webView: WKWebView())
        }
        return store.store(handler)
    }

    func webViewLoad(descriptor: Int32, requestDescriptor: Int32) -> Int32 {
        guard let handler = store.fetch(from: descriptor) as? LegacyWasmWebViewHandler else {
            return Result.invalidHandler.rawValue
        }
        guard
            let request = store.fetch(from: requestDescriptor) as? NetRequest,
            let urlRequest = request.toUrlRequest()
        else {
            return Result.invalidRequest.rawValue
        }
        aidokuLegacyRunOnMainThread {
            _ = handler.webView.load(urlRequest)
        }
        return Result.success.rawValue
    }

    func webViewLoadHtml(
        memory: Memory,
        descriptor: Int32,
        stringPointer: Int32,
        length: Int32,
        urlStringPointer: Int32,
        urlLength: Int32
    ) -> Int32 {
        guard let handler = store.fetch(from: descriptor) as? LegacyWasmWebViewHandler else {
            return Result.invalidHandler.rawValue
        }
        guard
            stringPointer >= 0,
            length > 0,
            let htmlString = try? memory.readString(offset: UInt32(stringPointer), length: UInt32(length))
        else {
            return Result.invalidString.rawValue
        }
        let url: URL?
        if
            urlStringPointer >= 0,
            urlLength > 0,
            let urlString = try? memory.readString(offset: UInt32(urlStringPointer), length: UInt32(urlLength))
        {
            url = URL(string: urlString)
        } else {
            url = nil
        }
        aidokuLegacyRunOnMainThread {
            _ = handler.webView.loadHTMLString(htmlString, baseURL: url)
        }
        return Result.success.rawValue
    }

    func webViewWaitForLoad(descriptor: Int32) -> Int32 {
        guard let handler = store.fetch(from: descriptor) as? LegacyWasmWebViewHandler else {
            return Result.invalidHandler.rawValue
        }
        handler.waitForLoad()
        return Result.success.rawValue
    }

    func webViewEval(memory: Memory, descriptor: Int32, stringPointer: Int32, length: Int32) -> Int32 {
        guard let handler = store.fetch(from: descriptor) as? LegacyWasmWebViewHandler else {
            return Result.invalidHandler.rawValue
        }
        guard
            stringPointer >= 0,
            length > 0,
            let jsString = try? memory.readString(offset: UInt32(stringPointer), length: UInt32(length))
        else {
            return Result.invalidString.rawValue
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultString: String?
        DispatchQueue.main.async {
            handler.webView.evaluateJavaScript(jsString) { result, _ in
                if let result = result {
                    resultString = "\(result)"
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        guard let resultString = resultString else {
            return Result.missingResult.rawValue
        }
        return store.store(resultString)
    }
}

private func aidokuLegacyRunOnMainThread<T>(_ block: @escaping () -> T) -> T {
    if Thread.isMainThread {
        return block()
    }
    var result: T!
    DispatchQueue.main.sync {
        result = block()
    }
    return result
}

private final class LegacyWasmWebViewHandler: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    private var loadSemaphore = DispatchSemaphore(value: 0)

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func waitForLoad() {
        loadSemaphore.wait()
        loadSemaphore = DispatchSemaphore(value: 0)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadSemaphore.signal()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadSemaphore.signal()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadSemaphore.signal()
    }
}

struct Canvas: SourceLibrary {
    static let namespace = "canvas"

    let module: Module
    let store: GlobalStore

    func link() throws {
        try? module.linkFunction(name: "new_context", namespace: Self.namespace, function: newContext)
        try? module.linkFunction(name: "set_transform", namespace: Self.namespace, function: setTransform)
        try? module.linkFunction(name: "draw_image", namespace: Self.namespace, function: drawImage)
        try? module.linkFunction(name: "copy_image", namespace: Self.namespace, function: copyImage)
        try? module.linkFunction(name: "fill", namespace: Self.namespace, function: fill)
        try? module.linkFunction(name: "stroke", namespace: Self.namespace, function: stroke)
        try? module.linkFunction(name: "draw_text", namespace: Self.namespace, function: drawText)
        try? module.linkFunction(name: "get_image", namespace: Self.namespace, function: getImage)
        try? module.linkFunction(name: "new_font", namespace: Self.namespace, function: newFont)
        try? module.linkFunction(name: "system_font", namespace: Self.namespace, function: systemFont)
        try? module.linkFunction(name: "load_font", namespace: Self.namespace, function: loadFont)
        try? module.linkFunction(name: "new_image", namespace: Self.namespace, function: newImage)
        try? module.linkFunction(name: "get_image_data", namespace: Self.namespace, function: getImageData)
        try? module.linkFunction(name: "get_image_width", namespace: Self.namespace, function: getImageWidth)
        try? module.linkFunction(name: "get_image_height", namespace: Self.namespace, function: getImageHeight)
    }

    enum Result: Int32 {
        case success = 0
        case invalidContext = -1
        case invalidImagePointer = -2
        case invalidImage = -3
        case invalidSrcRect = -4
        case invalidResult = -5
        case invalidBounds = -6
        case invalidPath = -7
        case invalidStyle = -8
        case invalidString = -9
        case invalidFont = -10
        case invalidData = -11
        case fontLoadFailed = -12
    }

    func newContext(width: Float32, height: Float32) -> Int32 {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            return Result.invalidBounds.rawValue
        }
        UIGraphicsBeginImageContextWithOptions(CGSize(width: CGFloat(width), height: CGFloat(height)), false, 1)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return Result.invalidContext.rawValue
        }
        return store.store(LegacyCanvasContext(context))
    }

    func setTransform(
        contextPtr: Int32,
        translateX: Float32,
        translateY: Float32,
        scaleX: Float32,
        scaleY: Float32,
        rotateAngle: Float32
    ) -> Int32 {
        guard let context = (store.fetch(from: contextPtr) as? LegacyCanvasContext)?.context else {
            return Result.invalidContext.rawValue
        }
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: CGFloat(translateX), y: CGFloat(translateY))
        context.scaleBy(x: CGFloat(scaleX), y: CGFloat(scaleY))
        context.rotate(by: CGFloat(rotateAngle))
        return Result.success.rawValue
    }

    func drawImage(
        contextPtr: Int32,
        imagePtr: Int32,
        dstX: Float32,
        dstY: Float32,
        dstWidth: Float32,
        dstHeight: Float32
    ) -> Int32 {
        guard let context = (store.fetch(from: contextPtr) as? LegacyCanvasContext)?.context else {
            return Result.invalidContext.rawValue
        }
        guard let cgImage = store.fetchImage(from: imagePtr)?.cgImage else {
            return Result.invalidImagePointer.rawValue
        }
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            cgImage,
            in: CGRect(
                x: CGFloat(dstX),
                y: CGFloat(context.height) - CGFloat(dstY) - CGFloat(dstHeight),
                width: CGFloat(dstWidth),
                height: CGFloat(dstHeight)
            )
        )
        context.restoreGState()
        return Result.success.rawValue
    }

    func copyImage(
        contextPtr: Int32,
        imagePtr: Int32,
        srcX: Float32,
        srcY: Float32,
        srcWidth: Float32,
        srcHeight: Float32,
        dstX: Float32,
        dstY: Float32,
        dstWidth: Float32,
        dstHeight: Float32
    ) -> Int32 {
        guard let context = (store.fetch(from: contextPtr) as? LegacyCanvasContext)?.context else {
            return Result.invalidContext.rawValue
        }
        guard let cgImage = store.fetchImage(from: imagePtr)?.cgImage else {
            return Result.invalidImagePointer.rawValue
        }
        let sourceRect = CGRect(
            x: CGFloat(srcX),
            y: CGFloat(srcY),
            width: CGFloat(srcWidth),
            height: CGFloat(srcHeight)
        )
        guard let sourceImage = cgImage.cropping(to: sourceRect) else {
            return Result.invalidSrcRect.rawValue
        }
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            sourceImage,
            in: CGRect(
                x: CGFloat(dstX),
                y: CGFloat(context.height) - CGFloat(dstY) - CGFloat(dstHeight),
                width: CGFloat(dstWidth),
                height: CGFloat(dstHeight)
            )
        )
        context.restoreGState()
        return Result.success.rawValue
    }

    func fill(
        memory: Memory,
        contextPtr: Int32,
        pathPtr: Int32,
        r: Float32,
        g: Float32,
        b: Float32,
        a: Float32
    ) -> Int32 {
        return Result.invalidPath.rawValue
    }

    func stroke(memory: Memory, contextPtr: Int32, pathPtr: Int32, stylePtr: Int32) -> Int32 {
        return Result.invalidPath.rawValue
    }

    func drawText(
        memory: Memory,
        contextPtr: Int32,
        textPtr: Int32,
        textLen: Int32,
        size: Float32,
        x: Float32,
        y: Float32,
        fontPtr: Int32,
        r: Float32,
        g: Float32,
        b: Float32,
        a: Float32
    ) -> Int32 {
        return Result.invalidFont.rawValue
    }

    func getImage(contextPtr: Int32) -> Int32 {
        guard store.fetch(from: contextPtr) is LegacyCanvasContext else {
            return Result.invalidContext.rawValue
        }
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let image = image else {
            return Result.invalidResult.rawValue
        }
        return store.store(image)
    }

    func newFont(memory: Memory, namePtr: Int32, nameLen: Int32) -> Int32 {
        guard
            namePtr >= 0,
            nameLen >= 0,
            let name = try? memory.readString(offset: UInt32(namePtr), length: UInt32(nameLen)),
            let font = UIFont(name: name, size: UIFont.systemFontSize)
        else {
            return Result.invalidFont.rawValue
        }
        return store.store(font)
    }

    func systemFont(weight: Int32) -> Int32 {
        return store.store(UIFont.systemFont(ofSize: UIFont.systemFontSize))
    }

    func loadFont(memory: Memory, urlPtr: Int32, urlLen: Int32) -> Int32 {
        return Result.fontLoadFailed.rawValue
    }

    func newImage(memory: Memory, dataPtr: Int32, dataLen: Int32) -> Int32 {
        guard
            dataPtr >= 0,
            dataLen >= 0,
            let data = try? memory.readData(offset: UInt32(dataPtr), length: UInt32(dataLen))
        else {
            return Result.invalidData.rawValue
        }
        guard let image = UIImage(data: data) else {
            return Result.invalidImage.rawValue
        }
        return store.store(image)
    }

    func getImageData(imagePtr: Int32) -> Int32 {
        if let data = store.fetch(from: imagePtr) as? Data {
            return store.store(data)
        }
        guard let data = store.fetchImage(from: imagePtr)?.pngData() else {
            return Result.invalidImagePointer.rawValue
        }
        return store.store(data)
    }

    func getImageWidth(imagePtr: Int32) -> Float32 {
        guard let image = store.fetchImage(from: imagePtr) else {
            return Float32(Result.invalidImagePointer.rawValue)
        }
        return Float32(image.size.width)
    }

    func getImageHeight(imagePtr: Int32) -> Float32 {
        guard let image = store.fetchImage(from: imagePtr) else {
            return Float32(Result.invalidImagePointer.rawValue)
        }
        return Float32(image.size.height)
    }
}

private final class LegacyCanvasContext {
    let context: CGContext

    init(_ context: CGContext) {
        self.context = context
        context.saveGState()
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

    func getImage(descriptor: Int32) -> Int32 {
        guard let request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard let data = request.responseData else {
            return Result.missingData.rawValue
        }
        return store.store(data)
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
            let value = response.allHeaderFields.first(where: { header in
                guard let field = header.key as? String else { return false }
                return field.caseInsensitiveCompare(keyString) == .orderedSame
            })?.value as? String
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
