//
//  LegacyCoreImports.swift
//  AidokuLegacy
//
//  iOS 12-compatible AidokuRunner import modules.
//

import Foundation
import CoreText
import JavaScriptCore
import SwiftSoup
import UIKit
import WebKit
import Wasm3Legacy

struct Env: SourceLibrary {
    static let namespace = "env"

    let module: Module
    let partialResultHandler: LegacyPartialResultHandler?
    let printHandler: (String) -> Void

    func link() throws {
        try module.linkFunction(name: "abort", namespace: Self.namespace, function: abort)
        try module.linkFunction(name: "print", namespace: Self.namespace, function: envPrint)
        try module.linkFunction(name: "sleep", namespace: Self.namespace, function: sleep)
        try module.linkFunction(name: "send_partial_result", namespace: Self.namespace, function: sendPartialResult)
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
        try module.linkFunction(name: "abort", namespace: Self.namespace, function: abort)
        try module.linkFunction(name: "print", namespace: Self.namespace, function: stdPrint)
        try module.linkFunction(name: "destroy", namespace: Self.namespace, function: destroy)
        try module.linkFunction(name: "buffer_len", namespace: Self.namespace, function: bufferLength)
        try module.linkFunction(name: "read_buffer", namespace: Self.namespace, function: readBuffer)
        try module.linkFunction(name: "current_date", namespace: Self.namespace, function: currentDate)
        try module.linkFunction(name: "utc_offset", namespace: Self.namespace, function: utcOffset)
        try module.linkFunction(name: "parse_date", namespace: Self.namespace, function: parseDate)
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
        try module.linkFunction(name: "get", namespace: Self.namespace, function: get)
        try module.linkFunction(name: "set", namespace: Self.namespace, function: set)
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
        try module.linkFunction(name: "context_create", namespace: Self.namespace, function: contextCreate)
        try module.linkFunction(name: "context_eval", namespace: Self.namespace, function: contextEval)
        try module.linkFunction(name: "context_get", namespace: Self.namespace, function: contextGet)
        try module.linkFunction(name: "webview_create", namespace: Self.namespace, function: webViewCreate)
        try module.linkFunction(name: "webview_load", namespace: Self.namespace, function: webViewLoad)
        try module.linkFunction(name: "webview_load_html", namespace: Self.namespace, function: webViewLoadHtml)
        try module.linkFunction(name: "webview_wait_for_load", namespace: Self.namespace, function: webViewWaitForLoad)
        try module.linkFunction(name: "webview_eval", namespace: Self.namespace, function: webViewEval)
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
        try module.linkFunction(name: "new_context", namespace: Self.namespace, function: newContext)
        try module.linkFunction(name: "set_transform", namespace: Self.namespace, function: setTransform)
        try module.linkFunction(name: "draw_image", namespace: Self.namespace, function: drawImage)
        try module.linkFunction(name: "copy_image", namespace: Self.namespace, function: copyImage)
        try module.linkFunction(name: "fill", namespace: Self.namespace, function: fill)
        try module.linkFunction(name: "stroke", namespace: Self.namespace, function: stroke)
        try module.linkFunction(name: "draw_text", namespace: Self.namespace, function: drawText)
        try module.linkFunction(name: "get_image", namespace: Self.namespace, function: getImage)
        try module.linkFunction(name: "new_font", namespace: Self.namespace, function: newFont)
        try module.linkFunction(name: "system_font", namespace: Self.namespace, function: systemFont)
        try module.linkFunction(name: "load_font", namespace: Self.namespace, function: loadFont)
        try module.linkFunction(name: "new_image", namespace: Self.namespace, function: newImage)
        try module.linkFunction(name: "get_image_data", namespace: Self.namespace, function: getImageData)
        try module.linkFunction(name: "get_image_width", namespace: Self.namespace, function: getImageWidth)
        try module.linkFunction(name: "get_image_height", namespace: Self.namespace, function: getImageHeight)
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
        guard let context = (store.fetch(from: contextPtr) as? LegacyCanvasContext)?.context else {
            return Result.invalidContext.rawValue
        }
        guard let path = LegacyCanvasPath.decode(memory: memory, pointer: pathPtr) else {
            return Result.invalidPath.rawValue
        }

        path.fill(
            in: context,
            color: UIColor(
                red: CGFloat(r),
                green: CGFloat(g),
                blue: CGFloat(b),
                alpha: CGFloat(a)
            ).cgColor
        )
        return Result.success.rawValue
    }

    func stroke(memory: Memory, contextPtr: Int32, pathPtr: Int32, stylePtr: Int32) -> Int32 {
        guard let context = (store.fetch(from: contextPtr) as? LegacyCanvasContext)?.context else {
            return Result.invalidContext.rawValue
        }
        guard let path = LegacyCanvasPath.decode(memory: memory, pointer: pathPtr) else {
            return Result.invalidPath.rawValue
        }
        guard let style = LegacyCanvasStrokeStyle.decode(memory: memory, pointer: stylePtr) else {
            return Result.invalidStyle.rawValue
        }

        path.stroke(in: context, style: style)
        return Result.success.rawValue
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
        guard let context = (store.fetch(from: contextPtr) as? LegacyCanvasContext)?.context else {
            return Result.invalidContext.rawValue
        }
        guard let font = store.fetch(from: fontPtr) as? UIFont else {
            return Result.invalidFont.rawValue
        }
        guard
            textPtr >= 0,
            textLen >= 0,
            let string = try? memory.readString(offset: UInt32(textPtr), length: UInt32(textLen))
        else {
            return Result.invalidString.rawValue
        }

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(
                red: CGFloat(r),
                green: CGFloat(g),
                blue: CGFloat(b),
                alpha: CGFloat(a)
            ),
            .font: font.withSize(CGFloat(size))
        ]
        let attributedString = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: CGFloat(x),
            y: CGFloat(context.height) - CGFloat(y) - bounds.height
        )
        CTLineDraw(line, context)

        context.restoreGState()
        return Result.success.rawValue
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
        let clampedWeight = UInt8(max(0, min(Int(weight), Int(UInt8.max))))
        let fontWeight = LegacyCanvasFontWeight(rawValue: clampedWeight) ?? .regular
        return store.store(UIFont.systemFont(ofSize: UIFont.systemFontSize, weight: fontWeight.uiFontWeight))
    }

    func loadFont(memory: Memory, urlPtr: Int32, urlLen: Int32) -> Int32 {
        guard
            urlPtr >= 0,
            urlLen >= 0,
            let urlString = try? memory.readString(offset: UInt32(urlPtr), length: UInt32(urlLen)),
            let url = URL(string: urlString)
        else {
            return Result.invalidString.rawValue
        }
        guard
            let dataProvider = CGDataProvider(url: url as CFURL),
            let font = CGFont(dataProvider)
        else {
            return Result.fontLoadFailed.rawValue
        }

        CTFontManagerRegisterGraphicsFont(font, nil)

        guard
            let name = font.postScriptName as? String,
            let uiFont = UIFont(name: name, size: UIFont.systemFontSize)
        else {
            return Result.fontLoadFailed.rawValue
        }

        return store.store(uiFont)
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

private struct LegacyCanvasPoint: Decodable {
    let x: Float32
    let y: Float32

    var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

private enum LegacyCanvasPathOp {
    case moveTo(LegacyCanvasPoint)
    case lineTo(LegacyCanvasPoint)
    case quadTo(LegacyCanvasPoint, LegacyCanvasPoint)
    case cubicTo(LegacyCanvasPoint, LegacyCanvasPoint, LegacyCanvasPoint)
    case arc(LegacyCanvasPoint, Float32, Float32, Float32)
    case close
}

extension LegacyCanvasPathOp: Decodable {
    private enum CodingKeys: CodingKey {
        case type
        case moveTo
        case lineTo
        case quadTo
        case cubicTo
        case arc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UInt8.self, forKey: .type)

        switch type {
        case 0:
            self = .moveTo(try container.decode(LegacyCanvasPoint.self, forKey: .moveTo))
        case 1:
            self = .lineTo(try container.decode(LegacyCanvasPoint.self, forKey: .lineTo))
        case 2:
            let first = try container.decode(LegacyCanvasPoint.self, forKey: .quadTo)
            let second = try container.decode(LegacyCanvasPoint.self, forKey: .quadTo)
            self = .quadTo(first, second)
        case 3:
            let first = try container.decode(LegacyCanvasPoint.self, forKey: .cubicTo)
            let second = try container.decode(LegacyCanvasPoint.self, forKey: .cubicTo)
            let third = try container.decode(LegacyCanvasPoint.self, forKey: .cubicTo)
            self = .cubicTo(first, second, third)
        case 4:
            let center = try container.decode(LegacyCanvasPoint.self, forKey: .arc)
            let radius = try container.decode(Float32.self, forKey: .arc)
            let startAngle = try container.decode(Float32.self, forKey: .arc)
            let sweepAngle = try container.decode(Float32.self, forKey: .arc)
            self = .arc(center, radius, startAngle, sweepAngle)
        case 5:
            self = .close
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Invalid canvas path op \(type)"
            )
        }
    }
}

private struct LegacyCanvasPath: Decodable {
    let ops: [LegacyCanvasPathOp]

    static func decode(memory: Memory, pointer: Int32) -> LegacyCanvasPath? {
        guard let data = LegacyCanvasPostcardData.read(memory: memory, pointer: pointer) else { return nil }
        return try? PostcardDecoder().decode(LegacyCanvasPath.self, from: data)
    }

    private func draw(in context: CGContext) {
        var pathOpen = false
        for op in ops {
            if !pathOpen {
                context.beginPath()
                pathOpen = true
            }
            switch op {
            case .moveTo(let point):
                context.move(to: point.cgPoint)
            case .lineTo(let point):
                context.addLine(to: point.cgPoint)
            case .quadTo(let point, let control):
                context.addQuadCurve(to: point.cgPoint, control: control.cgPoint)
            case .cubicTo(let point, let control1, let control2):
                context.addCurve(to: point.cgPoint, control1: control1.cgPoint, control2: control2.cgPoint)
            case .arc(let center, let radius, let startAngle, let sweepAngle):
                context.addArc(
                    center: center.cgPoint,
                    radius: CGFloat(radius),
                    startAngle: CGFloat(startAngle),
                    endAngle: CGFloat(abs(sweepAngle)),
                    clockwise: sweepAngle >= 0
                )
            case .close:
                context.closePath()
                pathOpen = false
            }
        }
    }

    func fill(in context: CGContext, color: CGColor) {
        context.saveGState()
        draw(in: context)
        context.setFillColor(color)
        context.fillPath()
        context.restoreGState()
    }

    func stroke(in context: CGContext, style: LegacyCanvasStrokeStyle) {
        context.saveGState()
        draw(in: context)
        style.apply(to: context)
        context.strokePath()
        context.restoreGState()
    }
}

private struct LegacyCanvasColor: Decodable {
    let red: Float32
    let green: Float32
    let blue: Float32
    let alpha: Float32

    var cgColor: CGColor {
        UIColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        ).cgColor
    }
}

private enum LegacyCanvasLineCap: UInt8, Decodable {
    case round = 0
    case square = 1
    case butt = 2

    var cgLineCap: CGLineCap {
        switch self {
        case .round:
            return .round
        case .square:
            return .square
        case .butt:
            return .butt
        }
    }
}

private enum LegacyCanvasLineJoin: UInt8, Decodable {
    case round = 0
    case bevel = 1
    case miter = 2

    var cgLineJoin: CGLineJoin {
        switch self {
        case .round:
            return .round
        case .bevel:
            return .bevel
        case .miter:
            return .miter
        }
    }
}

private struct LegacyCanvasStrokeStyle: Decodable {
    let color: LegacyCanvasColor
    let width: Float32
    let cap: LegacyCanvasLineCap
    let join: LegacyCanvasLineJoin
    let miterLimit: Float32
    let dashArray: [Float32]
    let dashOffset: Float32

    static func decode(memory: Memory, pointer: Int32) -> LegacyCanvasStrokeStyle? {
        guard let data = LegacyCanvasPostcardData.read(memory: memory, pointer: pointer) else { return nil }
        return try? PostcardDecoder().decode(LegacyCanvasStrokeStyle.self, from: data)
    }

    func apply(to context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(CGFloat(width))
        context.setLineCap(cap.cgLineCap)
        context.setLineJoin(join.cgLineJoin)
        context.setMiterLimit(CGFloat(miterLimit))
        if !dashArray.isEmpty {
            context.setLineDash(phase: CGFloat(dashOffset), lengths: dashArray.map { CGFloat($0) })
        }
    }
}

private enum LegacyCanvasFontWeight: UInt8 {
    case ultraLight = 0
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight:
            return .ultraLight
        case .thin:
            return .thin
        case .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        }
    }
}

private enum LegacyCanvasPostcardData {
    static func read(memory: Memory, pointer: Int32) -> Data? {
        guard pointer >= 0 else { return nil }
        let offset = UInt32(pointer)
        guard
            let length: UInt32 = try? memory.readValues(offset: offset, length: 1)[0],
            length >= 8
        else {
            return nil
        }
        return try? memory.readData(offset: offset + 8, length: length - 8)
    }
}

struct Net: SourceLibrary {
    static let namespace = "net"

    let module: Module
    let store: GlobalStore

    func link() throws {
        try module.linkFunction(name: "init", namespace: Self.namespace, function: initialize)
        try module.linkFunction(name: "send", namespace: Self.namespace, function: send)
        try module.linkFunction(name: "close", namespace: Self.namespace, function: close)
        try module.linkFunction(name: "send_all", namespace: Self.namespace, function: sendAll)
        try module.linkFunction(name: "set_url", namespace: Self.namespace, function: setUrl)
        try module.linkFunction(name: "set_header", namespace: Self.namespace, function: setHeader)
        try module.linkFunction(name: "set_body", namespace: Self.namespace, function: setBody)
        try module.linkFunction(name: "set_timeout", namespace: Self.namespace, function: setTimeout)
        try module.linkFunction(name: "data_len", namespace: Self.namespace, function: dataLength)
        try module.linkFunction(name: "read_data", namespace: Self.namespace, function: readData)
        try module.linkFunction(name: "get_image", namespace: Self.namespace, function: getImage)
        try module.linkFunction(name: "get_status_code", namespace: Self.namespace, function: getStatusCode)
        try module.linkFunction(name: "get_url", namespace: Self.namespace, function: getUrl)
        try module.linkFunction(name: "get_header", namespace: Self.namespace, function: getHeader)
        try module.linkFunction(name: "html", namespace: Self.namespace, function: dataToHtml)
        try module.linkFunction(name: "set_rate_limit", namespace: Self.namespace, function: setRateLimit)
        try module.linkFunction(name: "set_rate_limit_period", namespace: Self.namespace, function: setRateLimitPeriod)
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
            LegacyNetDiagnostics.shared.record("missing url for descriptor \(descriptor)")
            return Result.missingUrl.rawValue
        }

        // Routes through the system URLSession, falling back to OpenSSL for
        // TLS 1.3-only hosts (e.g. MangaDex) that iOS 12 cannot reach otherwise.
        let (responseData, response, responseError) = legacyPerformSourceRequest(urlRequest)

        request.responseData = responseData
        request.response = response
        request.responseError = responseError
        store.set(at: descriptor, item: request)

        let urlText = urlRequest.url?.absoluteString ?? "?"
        if let responseError = responseError {
            let nsError = responseError as NSError
            LegacyNetDiagnostics.shared.record("\(urlText) — \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            return Result.requestError.rawValue
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Source code may treat a non-2xx status as a request error; record the
            // status plus a short body snippet so the surfaced message names the
            // server's own reason (e.g. MangaDex 400 validation JSON, 403, 429).
            var detail = "\(urlText) — HTTP \(http.statusCode)"
            if let body = responseData, !body.isEmpty {
                let snippet = String(decoding: body.prefix(512), as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !snippet.isEmpty {
                    detail += ", body: \(snippet.prefix(300))"
                }
            }
            LegacyNetDiagnostics.shared.record(detail)
        }
        return Result.success.rawValue
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

    func close(descriptor: Int32) {
        guard descriptor >= 0 else { return }
        store.remove(at: descriptor)
    }

    func setUrl(memory: Memory, descriptor: Int32, value: Int32, length: Int32) -> Int32 {
        guard var request = store.fetch(from: descriptor) as? NetRequest else {
            return Result.invalidDescriptor.rawValue
        }
        guard
            value >= 0,
            length > 0,
            let urlString = try? memory.readString(offset: UInt32(value), length: UInt32(length)),
            let url = Self.lenientURL(from: urlString)
        else {
            return Result.invalidUrl.rawValue
        }
        request.url = url
        store.set(at: descriptor, item: request)
        return Result.success.rawValue
    }

    // iOS 12's `URL(string:)` is a strict RFC 3986 parser and returns nil for URLs
    // containing characters like `[` `]` `{` `}` `|` `^` or spaces. Newer OSes parse
    // such strings leniently. Sources like MangaDex build query strings with literal
    // brackets (e.g. `includes[]=cover_art`, `order[updatedAt]=desc`), so the strict
    // parser fails and the request is reported as a network error. Fall back to
    // percent-encoding the rejected characters, preserving existing `%XX` escapes.
    static func lenientURL(from string: String) -> URL? {
        if let url = URL(string: string) {
            return url
        }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#@!$&'()*+,;=%")
        if let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
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

    // Matches the current aidoku-rs signature `set_rate_limit(permits, period, unit)`.
    // Rate limiting is ignored in the legacy personal-use runner.
    func setRateLimit(permits _: Int32, period _: Int32, unit _: Int32) {
    }

    // Older sources imported a separate single-argument period setter. Kept linked
    // for backwards compatibility; the value is ignored.
    func setRateLimitPeriod(period _: Int32) {
    }
}
