//
//  LegacyRootViewController.swift
//  AidokuLegacy
//
//  Created for the iOS 12 compatibility target.
//

import UIKit
import WebKit
import ImageIO
import CoreImage
import SDWebImage
import SDWebImageWebPCoder
import avif
import ZIPFoundation

private let aidokuLegacyImageUserAgent = "Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
private let aidokuLegacyImageAcceptHeader = "image/avif,image/webp,image/*,*/*;q=0.8"

/// MangaDex's API and upload CDN reject browser-style `Mozilla/...` user agents
/// with an HTTP 400 (anti-scraping: they require a unique, identifying,
/// non-browser UA). Covers come from `uploads.mangadex.org`, so a browser image
/// UA leaves them blank. Other image hosts keep the browser UA — some gate
/// hotlinking on it. `*.mangadex.network` (reader pages) is intentionally not
/// matched: it serves over TLS 1.2 and does not gate on UA.
private func aidokuLegacyIsMangaDexHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "mangadex.org" || host.hasSuffix(".mangadex.org")
}

private func aidokuLegacyResolveImageUserAgent(for url: URL) -> String {
    guard aidokuLegacyIsMangaDexHost(url.host) else { return aidokuLegacyImageUserAgent }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    return "Aidoku/\(version) (iOS 12)"
}
private let aidokuLegacyImageDecodeQueue = DispatchQueue(label: "AidokuLegacy.imageDecode", qos: .utility)
private var aidokuLegacyLastMemoryPressureDate = Date.distantPast

func aidokuLegacyMarkMemoryPressure() {
    aidokuLegacyLastMemoryPressureDate = Date()
}

private func aidokuLegacyHasRecentMemoryPressure() -> Bool {
    return Date().timeIntervalSince(aidokuLegacyLastMemoryPressureDate) < 45
}

private func aidokuLegacyIsLowMemoryMode() -> Bool {
    if UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") {
        return true
    }
    return ProcessInfo.processInfo.physicalMemory <= 1_350_000_000
}

private func aidokuLegacyReaderMaxPixelHeight() -> CGFloat {
    let nativeScreenLimit = max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height)
    let sharpLowMemoryLimit = min(max(nativeScreenLimit, 1536), 2048)
    // Default low-memory pages now decode near the device's native resolution
    // instead of a soft 1024 px. Bounded at 1800 px so a fit-to-width MangaDex
    // page stays ~9 MB on a 1 GB iPad Air 1 (vs ~12.6 MB at full 2048).
    // Upscale mode still allows the full native limit for users who opt in.
    let balancedLowMemoryLimit = min(sharpLowMemoryLimit, 1800)
    let lowMemoryLimit: CGFloat = aidokuLegacyReaderUpscaleImages() ? sharpLowMemoryLimit : balancedLowMemoryLimit
    let normalLimit: CGFloat = 2200
    let limit = aidokuLegacyIsLowMemoryMode() ? lowMemoryLimit : normalLimit
    let storedValue = UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.maxImageHeight")
    if storedValue > 0 {
        if aidokuLegacyIsLowMemoryMode(), aidokuLegacyReaderUpscaleImages(), storedValue <= 1200 {
            return limit
        }
        return min(CGFloat(storedValue), limit)
    }
    return limit
}

private func aidokuLegacyReaderUpscaleImages() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.upscaleImages")
}

/// When incognito mode is on, the reader does not record history, reading
/// statistics, the resume session, or push progress to trackers.
func aidokuLegacyIncognitoEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.incognito")
}

/// Applies the opt-in reader image transforms (upscale, grayscale) that must be
/// baked into the cached bitmap. Cheap color transforms (brightness, color
/// filter, invert) are applied live as overlay layers instead — see
/// `LegacyReaderFilterOverlayView`.
private func aidokuLegacyPrepareReaderImageForDisplay(_ image: UIImage) -> UIImage {
    var result = image
    if aidokuLegacyReaderUpscaleImages() {
        result = aidokuLegacyUpscaleReaderImage(result)
    }
    if aidokuLegacyReaderCropBorders() {
        result = aidokuLegacyCropBordersReaderImage(result) ?? result
    }
    if aidokuLegacyReaderGrayscale() {
        result = aidokuLegacyGrayscaleReaderImage(result) ?? result
    }
    return result
}

/// Trims uniform (solid-color) margins around a page. Detection runs on a
/// downscaled copy to keep memory/CPU low on iPad Air 1-class devices; the
/// resulting crop ratios are mapped back onto the full-resolution image.
private func aidokuLegacyCropBordersReaderImage(_ image: UIImage) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let fullWidth = cgImage.width
    let fullHeight = cgImage.height
    guard fullWidth > 16, fullHeight > 16 else { return nil }

    let maxScanDimension = 320
    let scanScale = min(1.0, Double(maxScanDimension) / Double(max(fullWidth, fullHeight)))
    let scanWidth = max(8, Int(Double(fullWidth) * scanScale))
    let scanHeight = max(8, Int(Double(fullHeight) * scanScale))
    let bytesPerPixel = 4
    let bytesPerRow = scanWidth * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: scanWidth * scanHeight * bytesPerPixel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &pixels,
        width: scanWidth,
        height: scanHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    // Flip so buffer row 0 == top of the image, matching CGImage crop coords.
    context.translateBy(x: 0, y: CGFloat(scanHeight))
    context.scaleBy(x: 1, y: -1)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: scanWidth, height: scanHeight))

    func luma(_ x: Int, _ y: Int) -> Int {
        let offset = y * bytesPerRow + x * bytesPerPixel
        return (Int(pixels[offset]) * 299 + Int(pixels[offset + 1]) * 587 + Int(pixels[offset + 2]) * 114) / 1000
    }
    let corners = [luma(0, 0), luma(scanWidth - 1, 0), luma(0, scanHeight - 1), luma(scanWidth - 1, scanHeight - 1)]
    let background = corners.reduce(0, +) / corners.count
    let threshold = 28

    func rowHasContent(_ y: Int) -> Bool {
        for x in 0..<scanWidth where abs(luma(x, y) - background) > threshold { return true }
        return false
    }
    func columnHasContent(_ x: Int) -> Bool {
        for y in 0..<scanHeight where abs(luma(x, y) - background) > threshold { return true }
        return false
    }

    var top = 0
    while top < scanHeight - 1, !rowHasContent(top) { top += 1 }
    var bottom = scanHeight - 1
    while bottom > top, !rowHasContent(bottom) { bottom -= 1 }
    var left = 0
    while left < scanWidth - 1, !columnHasContent(left) { left += 1 }
    var right = scanWidth - 1
    while right > left, !columnHasContent(right) { right -= 1 }

    let cropX = Int(Double(left) / Double(scanWidth) * Double(fullWidth))
    let cropY = Int(Double(top) / Double(scanHeight) * Double(fullHeight))
    let cropRight = Int(Double(right + 1) / Double(scanWidth) * Double(fullWidth))
    let cropBottom = Int(Double(bottom + 1) / Double(scanHeight) * Double(fullHeight))
    let cropWidth = cropRight - cropX
    let cropHeight = cropBottom - cropY

    // Bail out on no-op or implausibly aggressive crops (near-uniform pages).
    guard cropWidth > fullWidth / 3, cropHeight > fullHeight / 3 else { return image }
    guard cropWidth < fullWidth || cropHeight < fullHeight else { return image }

    guard let cropped = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)) else {
        return nil
    }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}

private func aidokuLegacyUpscaleReaderImage(_ image: UIImage) -> UIImage {
    let maxPixelHeight = aidokuLegacyReaderMaxPixelHeight()
    let pixelHeight = image.size.height * image.scale
    let pixelWidth = image.size.width * image.scale
    guard pixelHeight > 0, pixelWidth > 0, pixelHeight < maxPixelHeight else {
        return image
    }

    let scale = min(maxPixelHeight / pixelHeight, 1.6)
    guard scale > 1.05 else { return image }
    let targetSize = CGSize(width: max(1, pixelWidth * scale), height: max(1, pixelHeight * scale))

    UIGraphicsBeginImageContextWithOptions(targetSize, false, 1)
    if let context = UIGraphicsGetCurrentContext() {
        context.interpolationQuality = .high
    }
    image.draw(in: CGRect(origin: .zero, size: targetSize))
    let upscaledImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return upscaledImage ?? image
}

/// Shared CoreImage context for reader page transforms. Created lazily so the
/// GPU context is only allocated when grayscale rendering is actually used.
private let aidokuLegacyReaderCIContext = CIContext(options: nil)

private func aidokuLegacyGrayscaleReaderImage(_ image: UIImage) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let ciImage = CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIColorControls") else { return nil }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(0, forKey: kCIInputSaturationKey)
    guard
        let output = filter.outputImage,
        let rendered = aidokuLegacyReaderCIContext.createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
}

private func aidokuLegacyReaderPrefetchCount() -> Int {
    let storedValue = UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.prefetchPages")
    if aidokuLegacyIsLowMemoryMode() {
        if aidokuLegacyHasRecentMemoryPressure() {
            return 0
        }
        return max(1, min(storedValue, 2))
    }
    let bounded = min(max(storedValue, 0), 3)
    return bounded
}

private func aidokuLegacyReaderRetainedPageDelay() -> TimeInterval {
    if aidokuLegacyHasRecentMemoryPressure() {
        return 1.5
    }
    if aidokuLegacyIsLowMemoryMode() {
        return aidokuLegacyReaderUpscaleImages() ? 2.5 : 4
    }
    return 15
}

private func aidokuLegacyReaderShowsPageNumber() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.showPageNumber")
}

private func aidokuLegacyReaderShowsTapZones() -> Bool {
    return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.showTapZones")
}

// MARK: - Reader color & display settings (Mihon parity)

/// Page background shown behind aspect-fit pages and in the gaps between them.
enum LegacyReaderBackground: String, CaseIterable {
    case system
    case white
    case black
    case gray

    static let defaultsKey = "AidokuLegacy.reader.backgroundColor"

    static var current: LegacyReaderBackground {
        if
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = LegacyReaderBackground(rawValue: raw)
        {
            return value
        }
        return .black
    }

    static func setCurrent(_ value: LegacyReaderBackground) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
            case .system: return "Automatic"
            case .white: return "White"
            case .black: return "Black"
            case .gray: return "Gray"
        }
    }

    var color: UIColor {
        switch self {
            case .system: return LegacyPalette.isDarkTheme ? .black : .white
            case .white: return .white
            case .black: return .black
            case .gray: return UIColor(white: 0.13, alpha: 1)
        }
    }
}

/// Blend mode used to mix the color filter tint with the page underneath.
enum LegacyReaderBlendMode: String, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
    case lighten
    case darken

    static let defaultsKey = "AidokuLegacy.reader.colorFilterBlend"

    static var current: LegacyReaderBlendMode {
        if
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = LegacyReaderBlendMode(rawValue: raw)
        {
            return value
        }
        return .normal
    }

    static func setCurrent(_ value: LegacyReaderBlendMode) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
            case .normal: return "Default"
            case .multiply: return "Multiply"
            case .screen: return "Screen"
            case .overlay: return "Overlay"
            case .lighten: return "Lighten"
            case .darken: return "Darken"
        }
    }

    /// CoreImage compositing-filter name for the overlay layer. `nil` keeps a
    /// plain alpha tint (the default blend).
    var compositingFilterName: String? {
        switch self {
            case .normal: return nil
            case .multiply: return "multiplyBlendMode"
            case .screen: return "screenBlendMode"
            case .overlay: return "overlayBlendMode"
            case .lighten: return "lightenBlendMode"
            case .darken: return "darkenBlendMode"
        }
    }
}

private enum LegacyReaderColorDefaults {
    static let colorFilterEnabled = "AidokuLegacy.reader.colorFilterEnabled"
    static let colorFilterRed = "AidokuLegacy.reader.colorFilterRed"
    static let colorFilterGreen = "AidokuLegacy.reader.colorFilterGreen"
    static let colorFilterBlue = "AidokuLegacy.reader.colorFilterBlue"
    static let colorFilterAlpha = "AidokuLegacy.reader.colorFilterAlpha"
    static let brightness = "AidokuLegacy.reader.brightness"
    static let grayscale = "AidokuLegacy.reader.grayscale"
    static let invert = "AidokuLegacy.reader.invert"
    static let keepScreenOn = "AidokuLegacy.reader.keepScreenOn"
    static let cropBorders = "AidokuLegacy.reader.cropBorders"
    static let animatePageTransitions = "AidokuLegacy.reader.animatePageTransitions"
    static let webtoonSidePadding = "AidokuLegacy.reader.webtoonSidePadding"
    static let invertTapZones = "AidokuLegacy.reader.invertTapZones"
    static let eInkFlash = "AidokuLegacy.reader.eInkFlash"
}

func aidokuLegacyReaderColorFilterEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.colorFilterEnabled)
}

/// Reads a stored 0...255 color channel, returning `defaultValue` when unset.
private func aidokuLegacyReaderColorComponent(_ key: String, default defaultValue: Int) -> Int {
    guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
    return min(max(UserDefaults.standard.integer(forKey: key), 0), 255)
}

/// Stored color filter as (red, green, blue, alpha) channels in 0...255.
func aidokuLegacyReaderColorComponents() -> (red: Int, green: Int, blue: Int, alpha: Int) {
    return (
        aidokuLegacyReaderColorComponent(LegacyReaderColorDefaults.colorFilterRed, default: 0),
        aidokuLegacyReaderColorComponent(LegacyReaderColorDefaults.colorFilterGreen, default: 0),
        aidokuLegacyReaderColorComponent(LegacyReaderColorDefaults.colorFilterBlue, default: 0),
        aidokuLegacyReaderColorComponent(LegacyReaderColorDefaults.colorFilterAlpha, default: 102)
    )
}

func aidokuLegacySetReaderColorComponent(_ key: String, value: Int) {
    UserDefaults.standard.set(min(max(value, 0), 255), forKey: key)
}

let aidokuLegacyReaderColorFilterRedKey = LegacyReaderColorDefaults.colorFilterRed
let aidokuLegacyReaderColorFilterGreenKey = LegacyReaderColorDefaults.colorFilterGreen
let aidokuLegacyReaderColorFilterBlueKey = LegacyReaderColorDefaults.colorFilterBlue
let aidokuLegacyReaderColorFilterAlphaKey = LegacyReaderColorDefaults.colorFilterAlpha

func aidokuLegacyReaderColorFilterColor() -> UIColor {
    let components = aidokuLegacyReaderColorComponents()
    return UIColor(
        red: CGFloat(components.red) / 255,
        green: CGFloat(components.green) / 255,
        blue: CGFloat(components.blue) / 255,
        alpha: CGFloat(components.alpha) / 255
    )
}

func aidokuLegacySetReaderColorFilterEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.colorFilterEnabled)
}

/// Darkening overlay strength, 0 (off) ... 0.9 (darkest).
func aidokuLegacyReaderBrightness() -> CGFloat {
    let value = UserDefaults.standard.double(forKey: LegacyReaderColorDefaults.brightness)
    return CGFloat(min(max(value, 0), 0.9))
}

func aidokuLegacySetReaderBrightness(_ value: CGFloat) {
    UserDefaults.standard.set(Double(min(max(value, 0), 0.9)), forKey: LegacyReaderColorDefaults.brightness)
}

func aidokuLegacyReaderGrayscale() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.grayscale)
}

func aidokuLegacySetReaderGrayscale(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.grayscale)
}

func aidokuLegacyReaderInvert() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.invert)
}

func aidokuLegacySetReaderInvert(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.invert)
}

func aidokuLegacyReaderKeepScreenOn() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.keepScreenOn)
}

func aidokuLegacySetReaderKeepScreenOn(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.keepScreenOn)
}

func aidokuLegacyReaderCropBorders() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.cropBorders)
}

func aidokuLegacySetReaderCropBorders(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.cropBorders)
}

/// Whether tap-driven page jumps animate. Defaults to true.
func aidokuLegacyReaderAnimatePageTransitions() -> Bool {
    guard UserDefaults.standard.object(forKey: LegacyReaderColorDefaults.animatePageTransitions) != nil else {
        return true
    }
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.animatePageTransitions)
}

func aidokuLegacySetReaderAnimatePageTransitions(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.animatePageTransitions)
}

func aidokuLegacyReaderEInkFlash() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.eInkFlash)
}

func aidokuLegacySetReaderEInkFlash(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.eInkFlash)
}

/// Per-side webtoon padding as a percentage (0...25) of the strip width.
/// Applies only to the vertical-scroll reader.
func aidokuLegacyReaderWebtoonSidePaddingPercent() -> Int {
    return min(max(UserDefaults.standard.integer(forKey: LegacyReaderColorDefaults.webtoonSidePadding), 0), 25)
}

func aidokuLegacyReaderWebtoonSidePadding() -> CGFloat {
    return CGFloat(aidokuLegacyReaderWebtoonSidePaddingPercent()) / 100
}

func aidokuLegacySetReaderWebtoonSidePaddingPercent(_ value: Int) {
    UserDefaults.standard.set(min(max(value, 0), 25), forKey: LegacyReaderColorDefaults.webtoonSidePadding)
}

// MARK: - Reader navigation layout (tap zones)

/// Horizontal tap-zone preset. The legacy reader maps taps to three bands:
/// a previous zone, a center menu zone, and a next zone.
enum LegacyReaderNavLayout: String, CaseIterable {
    case standard
    case edge
    case wide
    case disabled

    static let defaultsKey = "AidokuLegacy.reader.navLayout"

    static var current: LegacyReaderNavLayout {
        if
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = LegacyReaderNavLayout(rawValue: raw)
        {
            return value
        }
        return .standard
    }

    static func setCurrent(_ value: LegacyReaderNavLayout) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
            case .standard: return "Standard"
            case .edge: return "Edge"
            case .wide: return "Large Zones"
            case .disabled: return "Disabled"
        }
    }

    var detail: String {
        switch self {
            case .standard: return "Left/right thirds turn pages; center opens the menu."
            case .edge: return "Small left/right edges turn pages; large center menu."
            case .wide: return "Large left/right zones; small center menu."
            case .disabled: return "Tapping only toggles the menu."
        }
    }

    /// Right edge of the previous-page zone, as a fraction of width.
    var previousZoneEnd: CGFloat {
        switch self {
            case .standard: return 0.33
            case .edge: return 0.20
            case .wide: return 0.42
            case .disabled: return 0
        }
    }

    /// Left edge of the next-page zone, as a fraction of width.
    var nextZoneStart: CGFloat {
        switch self {
            case .standard: return 0.67
            case .edge: return 0.80
            case .wide: return 0.58
            case .disabled: return 1
        }
    }
}

enum LegacyReaderTapAction {
    case previous
    case next
    case menu
}

/// Double-page (spread) mode for the paged reader.
enum LegacyReaderDoublePageMode: String, CaseIterable {
    case off
    case on
    case auto

    static let defaultsKey = "AidokuLegacy.reader.doublePageMode"

    static var current: LegacyReaderDoublePageMode {
        if
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = LegacyReaderDoublePageMode(rawValue: raw)
        {
            return value
        }
        return .off
    }

    static func setCurrent(_ value: LegacyReaderDoublePageMode) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
            case .off: return "Off"
            case .on: return "On"
            case .auto: return "Automatic"
        }
    }

    var detail: String {
        switch self {
            case .off: return "Show one page at a time."
            case .on: return "Always show two pages side by side."
            case .auto: return "Two pages in landscape, one in portrait."
        }
    }
}

func aidokuLegacyReaderInvertTapZones() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyReaderColorDefaults.invertTapZones)
}

func aidokuLegacySetReaderInvertTapZones(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyReaderColorDefaults.invertTapZones)
}

/// Resolves a horizontal tap into a page/menu action for the current nav
/// layout. `nextOnLeft` is true for right-to-left paging, where the next page
/// sits on the left.
func aidokuLegacyReaderTapAction(xFraction: CGFloat, nextOnLeft: Bool) -> LegacyReaderTapAction {
    let layout = LegacyReaderNavLayout.current
    if layout == .disabled { return .menu }
    let inPreviousZone = xFraction < layout.previousZoneEnd
    let inNextZone = xFraction > layout.nextZoneStart
    guard inPreviousZone || inNextZone else { return .menu }

    // Base: left zone = previous, right zone = next. RTL paging and the invert
    // toggle each flip which side advances.
    var leftIsPrevious = !nextOnLeft
    if aidokuLegacyReaderInvertTapZones() { leftIsPrevious.toggle() }
    if inPreviousZone {
        return leftIsPrevious ? .previous : .next
    }
    return leftIsPrevious ? .next : .previous
}

/// Cache-key fragment so toggling grayscale or crop-borders never serves a
/// stale bitmap, and so the reader can detect a re-decode is needed.
private func aidokuLegacyReaderImageProcessingSignature() -> String {
    let grayscale = aidokuLegacyReaderGrayscale() ? "1" : "0"
    let crop = aidokuLegacyReaderCropBorders() ? "1" : "0"
    return "gray=\(grayscale),crop=\(crop)"
}

private func aidokuLegacyApplicationSupportDirectory() throws -> URL {
    guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw NSError(domain: "AidokuLegacy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable."])
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    return directory
}

func aidokuLegacySanitizedPathComponent(_ value: String) -> String {
    let dot: UnicodeScalar = "."
    let dash: UnicodeScalar = "-"
    let underscore: UnicodeScalar = "_"
    let sanitized = value.unicodeScalars.reduce(into: "") { result, scalar in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == dot || scalar == dash || scalar == underscore {
            result.unicodeScalars.append(scalar)
        } else {
            result.append("_")
        }
    }
    return sanitized.isEmpty ? UUID().uuidString : sanitized
}

private func aidokuLegacyPreparePagesForLowMemory(
    _ pages: [AidokuRunnerLegacyPage]
) -> (pages: [AidokuRunnerLegacyPage], temporaryDirectories: [URL]) {
    guard aidokuLegacyIsLowMemoryMode() else {
        return (pages, [])
    }

    var preparedPages = pages
    var temporaryDirectory: URL?
    for index in preparedPages.indices {
        guard case .image(let data) = preparedPages[index].content else { continue }
        guard !data.isEmpty else { continue }
        if temporaryDirectory == nil {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyInlinePages-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                temporaryDirectory = directory
            } catch {
                continue
            }
        }
        guard let directory = temporaryDirectory else { continue }
        let fileURL = directory.appendingPathComponent("page-\(index).img")
        do {
            try data.write(to: fileURL, options: .atomic)
            preparedPages[index].content = .url(fileURL, context: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    if let temporaryDirectory = temporaryDirectory {
        return (preparedPages, [temporaryDirectory])
    }
    return (preparedPages, [])
}

private func aidokuLegacyRemoveTemporaryPageDirectories(_ directories: [URL]) {
    for directory in directories {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Resolves `.zipFile` reader/download pages into in-memory image pages.
///
/// Some sources deliver a chapter as a single archive plus a per-page entry
/// path. The legacy reader and downloader only understand image/url/text
/// pages, so this resolver downloads each referenced archive once, extracts
/// the requested entry, and rewrites the page as `.image(data)`. Downstream
/// low-memory handling then relocates the bytes to a temp file as usual, so
/// nothing is held in memory longer than a single page on a 1 GB device.
final class LegacyZipPageResolver {
    static let shared = LegacyZipPageResolver()

    private let session = aidokuLegacyReaderImageSession
    private let queue = DispatchQueue(label: "AidokuLegacy.zipPageResolver", qos: .userInitiated)

    func resolve(
        _ pages: [AidokuRunnerLegacyPage],
        source: AidokuRunnerLegacySource,
        completion: @escaping ([AidokuRunnerLegacyPage]) -> Void
    ) {
        let hasZipPage = pages.contains {
            if case .zipFile = $0.content { return true }
            return false
        }
        guard hasZipPage else {
            completion(pages)
            return
        }

        queue.async {
            var result = pages
            var localArchives: [URL: URL] = [:]   // source archive URL -> local file on disk
            var downloadedArchives: [URL] = []     // temp copies to delete when finished

            for index in result.indices {
                guard case .zipFile(let archiveURL, let filePath) = result[index].content else { continue }

                let localArchiveURL: URL?
                if let cached = localArchives[archiveURL] {
                    localArchiveURL = cached
                } else if archiveURL.isFileURL {
                    localArchiveURL = archiveURL
                    localArchives[archiveURL] = archiveURL
                } else if let downloaded = self.downloadArchive(archiveURL, source: source) {
                    localArchiveURL = downloaded
                    localArchives[archiveURL] = downloaded
                    downloadedArchives.append(downloaded)
                } else {
                    localArchiveURL = nil
                }

                guard
                    let archiveFileURL = localArchiveURL,
                    let data = Self.extractEntry(from: archiveFileURL, filePath: filePath),
                    !data.isEmpty
                else {
                    continue // leave the page as .zipFile so the placeholder renders
                }
                result[index].content = .image(data)
            }

            for url in downloadedArchives {
                try? FileManager.default.removeItem(at: url)
            }
            completion(result)
        }
    }

    /// Synchronously downloads a remote archive to a temporary file.
    private func downloadArchive(_ url: URL, source: AidokuRunnerLegacySource) -> URL? {
        var request = URLRequest(url: url)
        if let referer = source.urls.first, let scheme = referer.scheme, let host = referer.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultURL: URL?
        let task = session.downloadTask(with: request) { location, response, _ in
            defer { semaphore.signal() }
            guard
                let location = location,
                (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else {
                return
            }
            let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyZip-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                resultURL = destination
            } catch {
                resultURL = nil
            }
        }
        task.resume()
        semaphore.wait()
        return resultURL
    }

    /// Extracts a single entry from a local archive into memory.
    static func extractEntry(from archiveURL: URL, filePath: String) -> Data? {
        guard let archive = Archive(url: archiveURL, accessMode: .read) else { return nil }
        guard let entry = archive[filePath] ?? Self.entry(in: archive, matching: filePath) else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data
    }

    /// Falls back to a case-insensitive / basename match when the exact path
    /// from the source does not line up with the archive's entry names.
    private static func entry(in archive: Archive, matching filePath: String) -> Entry? {
        let target = filePath.lowercased()
        let targetBase = (filePath as NSString).lastPathComponent.lowercased()
        return archive.first { entry in
            let path = entry.path.lowercased()
            return path == target || (path as NSString).lastPathComponent == targetBase
        }
    }
}

private func aidokuLegacySplitList(_ value: String?) -> [String] {
    guard let value = value else { return [] }
    return value
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func aidokuLegacyUsablePageDescription(_ description: String?) -> String? {
    guard let description = description else { return nil }
    return description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
}

private func aidokuLegacyResolvePageDescription(
    for page: AidokuRunnerLegacyPage,
    runner: AidokuRunnerLegacyRunner,
    completion: @escaping (String?) -> Void
) {
    if let description = aidokuLegacyUsablePageDescription(page.description) {
        completion(description)
        return
    }
    guard page.hasDescription else {
        completion(nil)
        return
    }
    runner.getPageDescription(page: page) { result in
        if case .success(let description) = result {
            completion(aidokuLegacyUsablePageDescription(description))
        } else {
            completion(nil)
        }
    }
}

private func aidokuLegacyChapterWebURL(_ chapter: AidokuRunnerLegacyChapter) -> URL? {
    guard
        let url = chapter.url,
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
    else {
        return nil
    }
    return url
}

private func aidokuLegacyOpenWebPage(url: URL, title: String, from viewController: UIViewController) {
    let webViewController = LegacySourceWebViewController(url: url, title: title)
    if let navigationController = viewController.navigationController {
        navigationController.pushViewController(webViewController, animated: true)
    } else {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

private let aidokuLegacyReaderImageSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.timeoutIntervalForRequest = 25
    configuration.timeoutIntervalForResource = 60
    configuration.httpMaximumConnectionsPerHost = aidokuLegacyIsLowMemoryMode() ? 2 : 3
    configuration.urlCache = URLCache(
        memoryCapacity: aidokuLegacyIsLowMemoryMode() ? 256 * 1024 : 6 * 1024 * 1024,
        diskCapacity: aidokuLegacyIsLowMemoryMode() ? 12 * 1024 * 1024 : 48 * 1024 * 1024,
        diskPath: "AidokuLegacyReaderImageCache"
    )
    configuration.httpAdditionalHeaders = [
        "Accept": aidokuLegacyImageAcceptHeader,
        "User-Agent": aidokuLegacyImageUserAgent
    ]
    return URLSession(configuration: configuration)
}()

private final class LegacyReaderImagePipeline {
    static let shared = LegacyReaderImagePipeline()

    private typealias Completion = (UIImage?) -> Void

    private let cache = NSCache<NSString, UIImage>()
    private let stateQueue = DispatchQueue(label: "AidokuLegacy.readerImagePipeline")
    private var waiters: [String: [Completion]] = [:]
    private var memoryObserver: NSObjectProtocol?

    private init() {
        configureCacheLimits()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            aidokuLegacyMarkMemoryPressure()
            self?.clear()
        }
    }

    deinit {
        if let memoryObserver = memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    func clear() {
        stateQueue.async { [weak self] in
            self?.configureCacheLimits()
            self?.cache.removeAllObjects()
        }
    }

    func preload(url: URL, context: [String: String]?, source: AidokuRunnerLegacySource) {
        load(url: url, context: context, source: source) { _ in }
    }

    func load(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        completion: @escaping (UIImage?) -> Void
    ) {
        if url.isFileURL {
            loadLocalFile(url: url, context: context, source: source, completion: completion)
            return
        }

        let cacheKey = self.cacheKey(url: url, context: context, source: source)
        guard startLoad(cacheKey: cacheKey, completion: completion) else { return }
        source.runner.getImageRequest(url: url, context: context) { [weak self] result in
            guard let self = self else { return }
            let request: URLRequest
            switch result {
                case .success(let imageRequest):
                    request = imageRequest.urlRequest(source: source, fallbackURL: url)
                case .failure:
                    request = legacyFallbackImageRequest(url: url, source: source)
            }
            let fallbackRequests = legacyFallbackImageRequests(url: url, source: source, excluding: request)
            self.fetchRemote(
                request: request,
                fallbackRequests: fallbackRequests,
                cacheKey: cacheKey,
                context: context,
                source: source,
                retriesRemaining: 1
            )
        }
    }

    private func loadLocalFile(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        completion: @escaping Completion
    ) {
        let cacheKey = localCacheKey(url: url, context: context, source: source)
        guard startLoad(cacheKey: cacheKey, completion: completion) else { return }
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                return LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            self?.finish(cacheKey: cacheKey, image: image)
        }
    }

    private func fetchRemote(
        request: URLRequest,
        fallbackRequests: [URLRequest],
        cacheKey: String,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        retriesRemaining: Int
    ) {
        aidokuLegacyReaderImageSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode
            if self.shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.fetchRemote(
                        request: request,
                        fallbackRequests: fallbackRequests,
                        cacheKey: cacheKey,
                        context: context,
                        source: source,
                        retriesRemaining: retriesRemaining - 1
                    )
                }
                return
            }

            guard
                let data = data,
                !data.isEmpty,
                let httpResponse = httpResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                self.fetchNextFallback(
                    fallbackRequests,
                    cacheKey: cacheKey,
                    context: context,
                    source: source
                )
                return
            }

            if source.runner.features.processesPages {
                DispatchQueue.main.async {
                    source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { result in
                        switch result {
                            case .success(let image?):
                                self.prepareProcessedImage(image, cacheKey: cacheKey)
                            case .success(nil), .failure:
                                self.decodeImageData(data, cacheKey: cacheKey)
                        }
                    }
                }
            } else {
                self.decodeImageData(data, cacheKey: cacheKey)
            }
        }.resume()
    }

    private func fetchNextFallback(
        _ fallbackRequests: [URLRequest],
        cacheKey: String,
        context: [String: String]?,
        source: AidokuRunnerLegacySource
    ) {
        guard let fallbackRequest = fallbackRequests.first else {
            finish(cacheKey: cacheKey, image: nil)
            return
        }
        let remainingRequests = Array(fallbackRequests.dropFirst())
        fetchRemote(
            request: fallbackRequest,
            fallbackRequests: remainingRequests,
            cacheKey: cacheKey,
            context: context,
            source: source,
            retriesRemaining: 1
        )
    }

    private func prepareProcessedImage(_ image: UIImage, cacheKey: String) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let preparedImage = autoreleasepool {
                aidokuLegacyPrepareReaderImageForDisplay(
                    LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                )
            }
            self?.finish(cacheKey: cacheKey, image: preparedImage)
        }
    }

    private func decodeImageData(_ data: Data, cacheKey: String) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool {
                LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            self?.finish(cacheKey: cacheKey, image: image)
        }
    }

    private func startLoad(cacheKey: String, completion: @escaping Completion) -> Bool {
        let key = cacheKey as NSString
        var cachedImage: UIImage?
        var shouldStart = false
        stateQueue.sync {
            if let image = cache.object(forKey: key) {
                cachedImage = image
            } else if waiters[cacheKey] != nil {
                waiters[cacheKey]?.append(completion)
            } else {
                waiters[cacheKey] = [completion]
                shouldStart = true
            }
        }
        if let cachedImage = cachedImage {
            completion(cachedImage)
        }
        return shouldStart
    }

    private func finish(cacheKey: String, image: UIImage?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if let image = image {
                self.cache.setObject(image, forKey: cacheKey as NSString, cost: self.imageCost(image))
            }
            let callbacks = self.waiters.removeValue(forKey: cacheKey) ?? []
            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    private func shouldRetry(error: Error?, statusCode: Int?, data: Data?) -> Bool {
        if error != nil || data == nil || data?.isEmpty == true {
            return true
        }
        guard let statusCode = statusCode else { return false }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func imageCost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        return max(1, Int(pixels * 4))
    }

    private func configureCacheLimits() {
        let prefetchCount = aidokuLegacyReaderPrefetchCount()
        let lowMemory = aidokuLegacyIsLowMemoryMode()
        let memoryPressure = aidokuLegacyHasRecentMemoryPressure()

        // Hold the entire prefetch window (both directions) plus a back-buffer
        // so swiping back to a recently viewed page is instant instead of
        // flashing "Loading...". Previously the cache (48 MB / ~3-4 decoded
        // 2200 px pages) was smaller than the prefetch window itself, so the
        // prefetched pages evicted each other and swiping back one page meant a
        // re-download and re-decode. Low-memory devices were worse: 10-16 MB
        // held barely one page, so every swipe reloaded.
        let windowPages = 2 * prefetchCount + 1
        let backBuffer = memoryPressure ? 1 : (lowMemory ? 2 : 4)
        let pagesToHold = max(3, windowPages + backBuffer)

        // Estimate the decoded cost from the reader's max pixel height (assume a
        // tall manga page at ~0.7 width:height) so the cost limit tracks the
        // real page size on this device instead of a fixed budget.
        let maxHeight = aidokuLegacyReaderMaxPixelHeight()
        let estimatedPageCost = max(1, Int(maxHeight * maxHeight * 0.7 * 4))
        var costCeiling = lowMemory ? 40 * 1024 * 1024 : 128 * 1024 * 1024
        if memoryPressure {
            costCeiling /= 2
        }

        cache.countLimit = pagesToHold
        cache.totalCostLimit = min(pagesToHold * estimatedPageCost, costCeiling)
    }

    private func localCacheKey(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource
    ) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return [
            "file",
            source.key,
            url.path,
            "\(values?.fileSize ?? 0)",
            "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)",
            contextKey(context),
            "\(Int(aidokuLegacyReaderMaxPixelHeight()))",
            aidokuLegacyReaderUpscaleImages() ? "upscale=1" : "upscale=0",
            aidokuLegacyReaderImageProcessingSignature()
        ].joined(separator: "\n")
    }

    private func cacheKey(
        url: URL,
        context: [String: String]?,
        source: AidokuRunnerLegacySource
    ) -> String {
        return [
            "remote",
            source.key,
            url.absoluteString,
            contextKey(context),
            "\(Int(aidokuLegacyReaderMaxPixelHeight()))",
            aidokuLegacyReaderUpscaleImages() ? "upscale=1" : "upscale=0",
            aidokuLegacyReaderImageProcessingSignature()
        ].joined(separator: "\n")
    }

    private func contextKey(_ context: [String: String]?) -> String {
        return (context ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }
}

func aidokuLegacyTrimVolatileCaches() {
    LegacyReaderImagePipeline.shared.clear()
    LegacyImageLoader.shared.clear()
    aidokuLegacyReaderImageSession.configuration.urlCache?.removeAllCachedResponses()
    URLCache.shared.removeAllCachedResponses()
    SDImageCache.shared.clearMemory()
}

enum LegacyPalette {
    static var isDarkTheme: Bool {
        return UserDefaults.standard.bool(forKey: "AidokuLegacy.appearance.darkTheme")
    }

    static var background: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
            : UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
    }

    static var panel: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
            : UIColor.white
    }

    static var primaryText: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
            : UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    }

    static var secondaryText: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.68, green: 0.69, blue: 0.72, alpha: 1)
            : UIColor(red: 0.34, green: 0.35, blue: 0.38, alpha: 1)
    }

    static var disabledText: UIColor {
        return isDarkTheme
            ? UIColor(red: 0.43, green: 0.44, blue: 0.47, alpha: 1)
            : UIColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1)
    }

    static let accent = UIColor(red: 0.83, green: 0.12, blue: 0.36, alpha: 1)

    static var barStyle: UIBarStyle {
        return isDarkTheme ? .black : .default
    }
}

private enum LegacyReaderMode: String, CaseIterable {
    case verticalScroll
    case verticalFit
    case pagedLTR
    case pagedRTL

    static let defaultsKey = "AidokuLegacy.reader.mode"

    static var current: LegacyReaderMode {
        if
            let rawValue = persistedRawValue,
            let mode = LegacyReaderMode(rawValue: rawValue)
        {
            return mode
        }
        return UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.fitToScreen") ? .verticalFit : .verticalScroll
    }

    static func setCurrent(_ mode: LegacyReaderMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        UserDefaults.standard.set(mode != .verticalScroll, forKey: "AidokuLegacy.reader.fitToScreen")
    }

    private static var persistedRawValue: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return UserDefaults.standard.string(forKey: defaultsKey)
        }
        return UserDefaults.standard.persistentDomain(forName: bundleID)?[defaultsKey] as? String
    }

    var title: String {
        switch self {
            case .verticalScroll:
                return "Vertical Scroll"
            case .verticalFit:
                return "Vertical Fit to Screen"
            case .pagedLTR:
                return "Paged Left to Right"
            case .pagedRTL:
                return "Paged Right to Left"
        }
    }

    var detail: String {
        switch self {
            case .verticalScroll:
                return "Continuous scrolling with page-height images"
            case .verticalFit:
                return "Each page fits within the visible screen"
            case .pagedLTR:
                return "Horizontal pages; swipe left for the next page"
            case .pagedRTL:
                return "Horizontal pages; swipe right for the next page"
        }
    }

    var usesPagedReader: Bool {
        switch self {
            case .pagedLTR, .pagedRTL:
                return true
            case .verticalScroll, .verticalFit:
                return false
        }
    }

}

extension Notification.Name {
    static let legacyInstalledSourcesDidChange = Notification.Name("AidokuLegacyInstalledSourcesDidChange")
    static let legacyLibraryDidChange = Notification.Name("AidokuLegacyLibraryDidChange")
    static let legacyHistoryDidChange = Notification.Name("AidokuLegacyHistoryDidChange")
    static let legacyAppearanceDidChange = Notification.Name("AidokuLegacyAppearanceDidChange")
    static let legacyDownloadsDidChange = Notification.Name("AidokuLegacyDownloadsDidChange")
    static let legacyUpdatesDidChange = Notification.Name("AidokuLegacyUpdatesDidChange")
    static let legacyAppDidEnterBackground = Notification.Name("AidokuLegacyAppDidEnterBackground")
    static let legacyAppWillEnterForeground = Notification.Name("AidokuLegacyAppWillEnterForeground")
    static let legacyMemoryTrimRequested = Notification.Name("AidokuLegacyMemoryTrimRequested")
    static let legacyReaderColorSettingsDidChange = Notification.Name("AidokuLegacyReaderColorSettingsDidChange")
}

private enum LegacyPrivacyDefaults {
    static let privacyShield = "AidokuLegacy.privacy.privacyShield"
}

func aidokuLegacyPrivacyShieldEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyPrivacyDefaults.privacyShield)
}

func aidokuLegacySetPrivacyShieldEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyPrivacyDefaults.privacyShield)
}

final class LegacyTabBarController: UITabBarController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var appearanceObserver: NSObjectProtocol?
    private var privacyResignObserver: NSObjectProtocol?
    private var privacyActiveObserver: NSObjectProtocol?
    private var privacyShieldView: UIView?
    private var didAttemptReaderRestore = false
    private var didStartAutomaticSourceUpdate = false

    override func viewDidLoad() {
        super.viewDidLoad()

        let library = UINavigationController(rootViewController: LegacyLibraryViewController())
        library.tabBarItem = UITabBarItem(tabBarSystemItem: .favorites, tag: 0)
        library.tabBarItem.title = "Library"

        let history = UINavigationController(rootViewController: LegacyHistoryViewController())
        history.tabBarItem = UITabBarItem(tabBarSystemItem: .history, tag: 1)
        history.tabBarItem.title = "History"

        let sources = UINavigationController(rootViewController: LegacyInstalledSourcesViewController())
        sources.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: 2)
        sources.tabBarItem.title = "Sources"

        let browse = UINavigationController(rootViewController: LegacyRootViewController())
        browse.tabBarItem = UITabBarItem(tabBarSystemItem: .downloads, tag: 3)
        browse.tabBarItem.title = "Browse"

        let settings = UINavigationController(rootViewController: LegacySettingsViewController())
        settings.tabBarItem = UITabBarItem(tabBarSystemItem: .more, tag: 4)
        settings.tabBarItem.title = "Settings"

        viewControllers = [library, history, sources, browse, settings]
        selectedIndex = LegacyLibraryStore.shared.entries.isEmpty ? 2 : 0
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .legacyAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        registerPrivacyShieldObservers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreLastReaderIfNeeded()
        updateInstalledSourcesIfNeeded()
    }

    deinit {
        if let appearanceObserver = appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let privacyResignObserver = privacyResignObserver {
            NotificationCenter.default.removeObserver(privacyResignObserver)
        }
        if let privacyActiveObserver = privacyActiveObserver {
            NotificationCenter.default.removeObserver(privacyActiveObserver)
        }
    }

    private func applyAppearance() {
        view.backgroundColor = LegacyPalette.background
        tabBar.tintColor = LegacyPalette.accent
        tabBar.barStyle = LegacyPalette.barStyle
        tabBar.barTintColor = LegacyPalette.panel
        viewControllers?.forEach { controller in
            guard let navigationController = controller as? UINavigationController else { return }
            navigationController.navigationBar.tintColor = LegacyPalette.accent
            navigationController.navigationBar.barStyle = LegacyPalette.barStyle
            navigationController.navigationBar.barTintColor = LegacyPalette.panel
            navigationController.navigationBar.titleTextAttributes = [.foregroundColor: LegacyPalette.primaryText]
            if #available(iOS 11.0, *) {
                navigationController.navigationBar.largeTitleTextAttributes = [.foregroundColor: LegacyPalette.primaryText]
            }
            if let tableController = navigationController.topViewController as? UITableViewController {
                tableController.view.backgroundColor = LegacyPalette.background
                tableController.tableView.backgroundColor = LegacyPalette.background
                tableController.tableView.reloadData()
            }
        }
    }

    private func restoreLastReaderIfNeeded() {
        guard !didAttemptReaderRestore else { return }
        didAttemptReaderRestore = true
        guard UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.restoreLastSession") else { return }
        guard let entry = LegacyReaderSessionStore.shared.entry else { return }
        guard Date().timeIntervalSince(entry.dateRead) < 7 * 24 * 60 * 60 else { return }
        let sources = packageInstaller.loadInstalledSources()
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else { return }
        guard let navigationController = viewControllers?[1] as? UINavigationController else { return }
        selectedIndex = 1
        navigationController.popToRootViewController(animated: false)
        navigationController.pushViewController(
            LegacyReaderFactory.makeReader(
                source: source,
                manga: entry.manga,
                chapter: entry.chapter,
                initialPageIndex: entry.pageIndex
            ),
            animated: false
        )
    }

    private func updateInstalledSourcesIfNeeded() {
        guard !didStartAutomaticSourceUpdate else { return }
        didStartAutomaticSourceUpdate = true
        LegacySourceUpdateManager.shared.updateInstalledSourcesIfNeeded(automatic: true)
    }

    func performBackgroundLibraryUpdate(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard
            let libraryNav = viewControllers?.first as? UINavigationController,
            let library = libraryNav.viewControllers.first as? LegacyLibraryViewController
        else {
            completion(.failed)
            return
        }
        library.performBackgroundFetchUpdate(completion: completion)
    }

    func openUpdatesFromNotification() {
        guard let libraryNav = viewControllers?.first as? UINavigationController else { return }
        selectedIndex = 0
        libraryNav.popToRootViewController(animated: false)
        if !(libraryNav.topViewController is LegacyUpdatesViewController) {
            libraryNav.pushViewController(LegacyUpdatesViewController(), animated: true)
        }
    }

    @discardableResult
    func openUpdatedManga(sourceKey: String, mangaKey: String) -> Bool {
        guard
            let libraryNav = viewControllers?.first as? UINavigationController,
            let entry = LegacyUpdateStore.shared.entries.first(where: {
                $0.sourceKey == sourceKey && $0.manga.key == mangaKey
            }),
            let source = packageInstaller.loadInstalledSources().first(where: { $0.key == sourceKey })
        else {
            return false
        }
        selectedIndex = 0
        libraryNav.popToRootViewController(animated: false)
        libraryNav.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entry.manga),
            animated: true
        )
        return true
    }

    private func registerPrivacyShieldObservers() {
        let center = NotificationCenter.default
        privacyResignObserver = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPrivacyShieldIfNeeded()
        }
        privacyActiveObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePrivacyShield()
        }
    }

    private func showPrivacyShieldIfNeeded() {
        guard aidokuLegacyPrivacyShieldEnabled(), privacyShieldView == nil else { return }
        let hostView: UIView
        if let window = view.window ?? UIApplication.shared.keyWindow {
            hostView = window
        } else {
            hostView = view
        }
        let shield = UIView(frame: hostView.bounds)
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shield.backgroundColor = LegacyPalette.background

        let label = UILabel()
        label.text = "Aidoku"
        label.textColor = LegacyPalette.accent
        label.font = .systemFont(ofSize: 32, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: shield.centerYAnchor)
        ])

        hostView.addSubview(shield)
        privacyShieldView = shield
    }

    private func hidePrivacyShield() {
        guard let shield = privacyShieldView else { return }
        privacyShieldView = nil
        UIView.animate(
            withDuration: 0.15,
            animations: { shield.alpha = 0 },
            completion: { _ in shield.removeFromSuperview() }
        )
    }
}

enum LegacyLibrarySortOption: String, CaseIterable {
    case recentlyAdded
    case title
    case source
    case unread
    case lastRead
    case totalChapters

    private static let defaultsKey = "AidokuLegacy.library.sortOption"

    static var current: LegacyLibrarySortOption {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let option = LegacyLibrarySortOption(rawValue: rawValue)
        else {
            return .recentlyAdded
        }
        return option
    }

    static func setCurrent(_ option: LegacyLibrarySortOption) {
        UserDefaults.standard.set(option.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
            case .recentlyAdded:
                return "Recently Added"
            case .title:
                return "Title"
            case .source:
                return "Source"
            case .unread:
                return "Unread Count"
            case .lastRead:
                return "Last Read"
            case .totalChapters:
                return "Total Chapters"
        }
    }
}

/// Tri-state library filter (Mihon parity): off, include-only, or exclude.
enum LegacyLibraryFilterState: Int {
    case off = 0
    case include = 1
    case exclude = 2

    var next: LegacyLibraryFilterState {
        switch self {
            case .off: return .include
            case .include: return .exclude
            case .exclude: return .off
        }
    }

    var indicator: String {
        switch self {
            case .off: return ""
            case .include: return " — Include"
            case .exclude: return " — Exclude"
        }
    }
}

/// Mihon-style library status filters.
enum LegacyLibraryStatusFilter: String, CaseIterable {
    case downloaded
    case unread
    case started
    case tracked

    var title: String {
        switch self {
            case .downloaded: return "Downloaded"
            case .unread: return "Unread"
            case .started: return "Started"
            case .tracked: return "Tracked"
        }
    }
}

enum LegacyLibraryStatusFilterStore {
    private static let key = "AidokuLegacy.library.statusFilters"

    static func states() -> [String: Int] {
        return UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func state(_ filter: LegacyLibraryStatusFilter) -> LegacyLibraryFilterState {
        return LegacyLibraryFilterState(rawValue: states()[filter.rawValue] ?? 0) ?? .off
    }

    static func setState(_ state: LegacyLibraryFilterState, for filter: LegacyLibraryStatusFilter) {
        var map = states()
        if state == .off {
            map.removeValue(forKey: filter.rawValue)
        } else {
            map[filter.rawValue] = state.rawValue
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var hasActiveFilters: Bool {
        return !states().isEmpty
    }
}

/// Library grid vs. list display mode, persisted across launches.
enum LegacyLibraryDisplayMode: String {
    case grid
    case list

    private static let defaultsKey = "AidokuLegacy.library.displayMode"

    static var current: LegacyLibraryDisplayMode {
        guard
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let mode = LegacyLibraryDisplayMode(rawValue: raw)
        else {
            return .grid
        }
        return mode
    }

    static func setCurrent(_ mode: LegacyLibraryDisplayMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}

/// User-managed library categories: an ordered, named list plus a default
/// category for new additions and per-category sort overrides. The category
/// strings live alongside the existing free-text categories on
/// `LegacyLibraryEntry`; this store owns the explicit list so empty categories
/// survive and can be reordered/renamed.
final class LegacyCategoryStore {
    static let shared = LegacyCategoryStore()

    /// Sentinel sort keys for the non-category library views. The leading
    /// control character keeps them from colliding with a real category name.
    static let allKey = "\u{1}all"
    static let uncategorizedKey = "\u{1}uncategorized"

    private let listKey = "AidokuLegacy.library.categoryList"
    private let defaultKey = "AidokuLegacy.library.defaultCategory"
    private let sortMapKey = "AidokuLegacy.library.categorySortMap"

    /// User-managed, ordered category names.
    var categories: [String] {
        LegacyLibraryEntry.normalizedList(UserDefaults.standard.stringArray(forKey: listKey) ?? [])
    }

    /// Managed categories plus any straggler categories that exist only on
    /// library entries (assigned via free-text before the list existed).
    func allCategories() -> [String] {
        var result = categories
        for value in LegacyLibraryStore.shared.categories()
        where !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            result.append(value)
        }
        return result
    }

    func contains(_ name: String) -> Bool {
        categories.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func add(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(trimmed) else { return false }
        save(categories + [trimmed])
        return true
    }

    func rename(_ old: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = categories
        guard let index = list.firstIndex(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) else { return }
        if let dup = list.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }), dup != index {
            // Merging into an existing name: drop the old slot.
            list.remove(at: index)
        } else {
            list[index] = trimmed
        }
        save(list)
        LegacyLibraryStore.shared.renameCategory(old, to: trimmed)
        if defaultCategory.caseInsensitiveCompare(old) == .orderedSame {
            defaultCategory = trimmed
        }
        migrateSort(from: old, to: trimmed)
    }

    func remove(_ name: String) {
        save(categories.filter { $0.caseInsensitiveCompare(name) != .orderedSame })
        LegacyLibraryStore.shared.renameCategory(name, to: nil)
        if defaultCategory.caseInsensitiveCompare(name) == .orderedSame {
            defaultCategory = ""
        }
        migrateSort(from: name, to: nil)
    }

    func move(from: Int, to: Int) {
        var list = categories
        guard list.indices.contains(from) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: min(max(to, 0), list.count))
        save(list)
    }

    /// Category that new library additions are filed under (empty = none).
    var defaultCategory: String {
        get { UserDefaults.standard.string(forKey: defaultKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultKey)
            NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
        }
    }

    func defaultCategoriesForNewEntry() -> [String] {
        let value = defaultCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? [] : [value]
    }

    /// Resolve the sort for a given library view. The "All" view always tracks
    /// the global `LegacyLibrarySortOption.current`; categories may override it.
    func sort(forKey key: String) -> LegacyLibrarySortOption {
        if
            key != Self.allKey,
            let raw = sortMap()[key],
            let option = LegacyLibrarySortOption(rawValue: raw)
        {
            return option
        }
        return LegacyLibrarySortOption.current
    }

    func setSort(_ option: LegacyLibrarySortOption, forKey key: String) {
        if key == Self.allKey {
            LegacyLibrarySortOption.setCurrent(option)
            var map = sortMap()
            map[key] = nil
            saveSortMap(map)
        } else {
            var map = sortMap()
            map[key] = option.rawValue
            saveSortMap(map)
        }
    }

    func hasSortOverride(forKey key: String) -> Bool {
        key != Self.allKey && sortMap()[key] != nil
    }

    func clearSortOverride(forKey key: String) {
        var map = sortMap()
        map[key] = nil
        saveSortMap(map)
    }

    private func migrateSort(from old: String, to newName: String?) {
        var map = sortMap()
        if let raw = map.removeValue(forKey: old), let newName = newName {
            map[newName] = raw
        }
        saveSortMap(map)
    }

    private func sortMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: sortMapKey) as? [String: String] ?? [:]
    }

    private func saveSortMap(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: sortMapKey)
    }

    private func save(_ values: [String]) {
        UserDefaults.standard.set(LegacyLibraryEntry.normalizedList(values), forKey: listKey)
        NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
    }
}

private extension AidokuRunnerLegacyManga {
    func mergedWithUpdate(_ update: AidokuRunnerLegacyManga) -> AidokuRunnerLegacyManga {
        var manga = update
        if manga.sourceKey.isEmpty {
            manga.sourceKey = sourceKey
        }
        if manga.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manga.title = title
        }
        manga.cover = Self.nonEmpty(manga.cover) ?? Self.nonEmpty(cover)
        manga.artists = manga.artists ?? artists
        manga.authors = manga.authors ?? authors
        manga.description = manga.description ?? description
        manga.url = manga.url ?? url
        manga.tags = manga.tags ?? tags
        manga.chapters = manga.chapters ?? chapters
        return manga
    }

    var legacyTagText: String? {
        let values = LegacyLibraryEntry.normalizedList(tags ?? [])
        guard !values.isEmpty else { return nil }
        return values.prefix(8).joined(separator: ", ")
    }

    var legacySummaryText: String? {
        var components: [String] = []
        if let authors = authors, !authors.isEmpty {
            components.append(authors.joined(separator: ", "))
        } else if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            components.append(description)
        }
        if let tagText = legacyTagText {
            components.append("Tags: \(tagText)")
        }
        return components.isEmpty ? nil : components.joined(separator: "\n")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct LegacyLibraryEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var dateAdded: Date
    var category: String?
    var categories: [String]

    var key: String {
        return "\(sourceKey)::\(manga.key)"
    }

    var displayCategories: [String] {
        let values = Self.normalizedList(categories)
        if !values.isEmpty {
            return values
        }
        return Self.normalizedList(category.map { [$0] } ?? [])
    }

    init(
        sourceKey: String,
        sourceName: String,
        manga: AidokuRunnerLegacyManga,
        dateAdded: Date,
        category: String?,
        categories: [String] = []
    ) {
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.manga = manga
        self.dateAdded = dateAdded
        self.category = category
        self.categories = Self.normalizedList(categories.isEmpty ? category.map { [$0] } ?? [] : categories)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceKey = try container.decode(String.self, forKey: .sourceKey)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        manga = try container.decode(AidokuRunnerLegacyManga.self, forKey: .manga)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        let decodedCategories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        categories = Self.normalizedList(decodedCategories.isEmpty ? category.map { [$0] } ?? [] : decodedCategories)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceKey, forKey: .sourceKey)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(manga, forKey: .manga)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encode(categories, forKey: .categories)
    }

    enum CodingKeys: String, CodingKey {
        case sourceKey
        case sourceName
        case manga
        case dateAdded
        case category
        case categories
    }

    static func normalizedList(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                result.append(trimmed)
            }
        }
        return result
    }
}

struct LegacyLibraryFilterGroup: Codable, Hashable {
    var id: String
    var name: String
    var categories: [String]
    var tags: [String]
    var matchAll: Bool

    var detailText: String {
        var components: [String] = []
        if !categories.isEmpty {
            components.append("Categories: \(categories.joined(separator: ", "))")
        }
        if !tags.isEmpty {
            components.append("Tags: \(tags.joined(separator: ", "))")
        }
        return components.isEmpty ? "No filters" : components.joined(separator: " - ")
    }
}

final class LegacyLibraryFilterGroupStore {
    static let shared = LegacyLibraryFilterGroupStore()

    private let defaultsKey = "AidokuLegacy.library.filterGroups"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var groups: [LegacyLibraryFilterGroup] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let groups = try? decoder.decode([LegacyLibraryFilterGroup].self, from: data)
        else {
            return []
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ group: LegacyLibraryFilterGroup) {
        var current = groups.filter { $0.id != group.id }
        current.append(group)
        save(current)
    }

    func remove(id: String) {
        save(groups.filter { $0.id != id })
    }

    func replace(_ groups: [LegacyLibraryFilterGroup]) {
        save(groups)
    }

    func clear() {
        save([])
    }

    private func save(_ groups: [LegacyLibraryFilterGroup]) {
        if let data = try? encoder.encode(groups) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
        }
    }
}

final class LegacyLibraryStore {
    static let shared = LegacyLibraryStore()

    private let defaultsKey = "AidokuLegacy.library.entries"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // In-memory cache of the decoded library. Previously `rawEntries` re-decoded
    // the entire UserDefaults blob on every access, and the launch path plus the
    // library/history table views hit it many times per refresh. Decoding once
    // and reusing the result keeps startup and scrolling fast.
    private let cacheLock = NSLock()
    private var cachedRawEntries: [LegacyLibraryEntry]?

    init() {
        // External writers (backup restore, deep-link import) mutate the stored
        // library without going through `save`, but they all post this
        // notification, so invalidate the cache whenever the library changes.
        NotificationCenter.default.addObserver(
            forName: .legacyLibraryDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateCache()
        }
    }

    private func invalidateCache() {
        cacheLock.lock()
        cachedRawEntries = nil
        cacheLock.unlock()
    }

    var entries: [LegacyLibraryEntry] {
        return entries(sort: .recentlyAdded)
    }

    var rawEntries: [LegacyLibraryEntry] {
        cacheLock.lock()
        if let cached = cachedRawEntries {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let decoded: [LegacyLibraryEntry]
        if
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyLibraryEntry].self, from: data)
        {
            decoded = entries
        } else {
            decoded = []
        }

        cacheLock.lock()
        cachedRawEntries = decoded
        cacheLock.unlock()
        return decoded
    }

    func entries(
        category: String? = nil,
        filterGroup: LegacyLibraryFilterGroup? = nil,
        query: String? = nil,
        sort: LegacyLibrarySortOption = .recentlyAdded
    ) -> [LegacyLibraryEntry] {
        var filteredEntries = rawEntries
        if let category = category {
            if category.isEmpty {
                filteredEntries = filteredEntries.filter { $0.displayCategories.isEmpty }
            } else {
                filteredEntries = filteredEntries.filter { entry in
                    entry.displayCategories.contains { $0.caseInsensitiveCompare(category) == .orderedSame }
                }
            }
        }
        if let filterGroup = filterGroup {
            filteredEntries = filteredEntries.filter { matchesFilterGroup(filterGroup, entry: $0) }
        }
        filteredEntries = applyStatusFilters(filteredEntries)
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuery.isEmpty {
            filteredEntries = filteredEntries.filter {
                $0.manga.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.sourceName.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.displayCategories.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
                    || ($0.manga.tags?.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) } ?? false)
            }
        }
        return sortEntries(filteredEntries, sort: sort)
    }

    func categories() -> [String] {
        let values = rawEntries.flatMap { $0.displayCategories }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func tags() -> [String] {
        let values = rawEntries.flatMap { $0.manga.tags ?? [] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func contains(sourceKey: String, mangaKey: String) -> Bool {
        return rawEntries.contains { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    func entry(sourceKey: String, mangaKey: String) -> LegacyLibraryEntry? {
        return rawEntries.first { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    func add(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = rawEntries.filter { !($0.sourceKey == source.key && $0.manga.key == manga.key) }
        let categories = LegacyCategoryStore.shared.defaultCategoriesForNewEntry()
        current.insert(
            LegacyLibraryEntry(
                sourceKey: source.key,
                sourceName: source.name,
                manga: manga,
                dateAdded: Date(),
                category: categories.first,
                categories: categories
            ),
            at: 0
        )
        save(current)
    }

    /// Re-tag every entry that uses `old`. Pass `to: nil` to drop the category.
    func renameCategory(_ old: String, to newName: String?) {
        var current = rawEntries
        var didChange = false
        for index in current.indices {
            let cats = current[index].displayCategories
            guard cats.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) else { continue }
            var updated: [String] = []
            for category in cats {
                if category.caseInsensitiveCompare(old) == .orderedSame {
                    if let newName = newName { updated.append(newName) }
                } else {
                    updated.append(category)
                }
            }
            let normalized = LegacyLibraryEntry.normalizedList(updated)
            current[index].categories = normalized
            current[index].category = normalized.first
            didChange = true
        }
        if didChange {
            save(current)
        }
    }

    func update(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = rawEntries
        guard let index = current.firstIndex(where: { $0.sourceKey == source.key && $0.manga.key == manga.key }) else {
            return
        }
        let mergedManga = current[index].manga.mergedWithUpdate(manga)
        current[index] = LegacyLibraryEntry(
            sourceKey: source.key,
            sourceName: source.name,
            manga: mergedManga,
            dateAdded: current[index].dateAdded,
            category: current[index].category,
            categories: current[index].displayCategories
        )
        save(current)
    }

    func updateMangaMetadata(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = rawEntries
        var didChange = false
        for index in current.indices where current[index].sourceKey == source.key && current[index].manga.key == manga.key {
            let mergedManga = current[index].manga.mergedWithUpdate(manga)
            if mergedManga != current[index].manga {
                current[index].manga = mergedManga
                current[index].sourceName = source.name
                didChange = true
            }
        }
        if didChange {
            save(current)
        }
    }

    func setCategory(sourceKey: String, mangaKey: String, category: String?) {
        setCategories(sourceKey: sourceKey, mangaKey: mangaKey, categories: category.map { [$0] } ?? [])
    }

    func setCategories(sourceKey: String, mangaKey: String, categories: [String]) {
        var current = rawEntries
        guard let index = current.firstIndex(where: { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }) else {
            return
        }
        let normalizedCategories = LegacyLibraryEntry.normalizedList(categories)
        current[index].categories = normalizedCategories
        current[index].category = normalizedCategories.first
        save(current)
    }

    func remove(sourceKey: String, mangaKey: String) {
        save(rawEntries.filter { !($0.sourceKey == sourceKey && $0.manga.key == mangaKey) })
    }

    func clear() {
        save([])
    }

    func replace(_ entries: [LegacyLibraryEntry]) {
        save(entries)
    }

    private func entries(sort: LegacyLibrarySortOption) -> [LegacyLibraryEntry] {
        return sortEntries(rawEntries, sort: sort)
    }

    private func sortEntries(_ entries: [LegacyLibraryEntry], sort: LegacyLibrarySortOption) -> [LegacyLibraryEntry] {
        switch sort {
            case .recentlyAdded:
                return entries.sorted { $0.dateAdded > $1.dateAdded }
            case .title:
                return entries.sorted { $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title) == .orderedAscending }
            case .source:
                return entries.sorted {
                    let sourceCompare = $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName)
                    if sourceCompare != .orderedSame {
                        return sourceCompare == .orderedAscending
                    }
                    return $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title) == .orderedAscending
                }
            case .unread:
                return entries.sorted { unreadCount(for: $0) > unreadCount(for: $1) }
            case .lastRead:
                return entries.sorted {
                    let lhs = LegacyHistoryStore.shared.latest(sourceKey: $0.sourceKey, mangaKey: $0.manga.key)?.dateRead ?? .distantPast
                    let rhs = LegacyHistoryStore.shared.latest(sourceKey: $1.sourceKey, mangaKey: $1.manga.key)?.dateRead ?? .distantPast
                    return lhs > rhs
                }
            case .totalChapters:
                return entries.sorted { ($0.manga.chapters?.count ?? 0) > ($1.manga.chapters?.count ?? 0) }
        }
    }

    private func unreadCount(for entry: LegacyLibraryEntry) -> Int {
        guard let chapters = entry.manga.chapters, !chapters.isEmpty else { return 0 }
        let readKeys = LegacyHistoryStore.shared.readChapterKeys(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
        return chapters.filter { !$0.locked && !readKeys.contains($0.key) }.count
    }

    /// Applies the active Mihon-style status filters (downloaded/unread/started/
    /// tracked), each tri-state include/exclude.
    private func applyStatusFilters(_ entries: [LegacyLibraryEntry]) -> [LegacyLibraryEntry] {
        var result = entries
        for filter in LegacyLibraryStatusFilter.allCases {
            let state = LegacyLibraryStatusFilterStore.state(filter)
            guard state != .off else { continue }
            result = result.filter { entry in
                let matches = entryMatchesStatus(filter, entry: entry)
                return state == .include ? matches : !matches
            }
        }
        return result
    }

    private func entryMatchesStatus(_ filter: LegacyLibraryStatusFilter, entry: LegacyLibraryEntry) -> Bool {
        switch filter {
            case .downloaded:
                return LegacyDownloadStore.shared.hasDownloads(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
            case .unread:
                return unreadCount(for: entry) > 0
            case .started:
                return LegacyHistoryStore.shared.latest(sourceKey: entry.sourceKey, mangaKey: entry.manga.key) != nil
            case .tracked:
                return !LegacyTrackerManager.shared.entries(sourceKey: entry.sourceKey, mangaKey: entry.manga.key).isEmpty
        }
    }

    private func matchesFilterGroup(_ group: LegacyLibraryFilterGroup, entry: LegacyLibraryEntry) -> Bool {
        var checks: [Bool] = []
        if !group.categories.isEmpty {
            checks.append(group.categories.contains { category in
                entry.displayCategories.contains { $0.caseInsensitiveCompare(category) == .orderedSame }
            })
        }
        if !group.tags.isEmpty {
            let entryTags = entry.manga.tags ?? []
            checks.append(group.tags.contains { tag in
                entryTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            })
        }
        guard !checks.isEmpty else { return true }
        return group.matchAll ? !checks.contains(false) : checks.contains(true)
    }

    private func save(_ entries: [LegacyLibraryEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyLibraryDidChange, object: nil)
        }
    }
}

struct LegacyHistoryEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
    var pageIndex: Int
    var pageCount: Int
    var dateRead: Date

    var key: String {
        return "\(sourceKey)::\(manga.key)::\(chapter.key)"
    }
}

final class LegacyHistoryStore {
    static let shared = LegacyHistoryStore()

    private let defaultsKey = "AidokuLegacy.history.entries"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // In-memory cache of the decoded, sorted history. `entries` was previously
    // decoding the entire UserDefaults blob (up to 250 entries, each carrying a
    // full manga + chapters) and sorting it on every access. `readChapterKeys`
    // calls it, the library grid's `unreadCount` calls `readChapterKeys` once per
    // cell, so scrolling the library re-decoded the whole history for every cover
    // — the main source of scroll jank. Decode once and reuse, mirroring
    // LegacyLibraryStore.
    private let cacheLock = NSLock()
    private var cachedEntries: [LegacyHistoryEntry]?

    init() {
        // External writers mutate the stored history without going through `save`
        // but post this notification, so invalidate whenever history changes.
        NotificationCenter.default.addObserver(
            forName: .legacyHistoryDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateCache()
        }
    }

    private func invalidateCache() {
        cacheLock.lock()
        cachedEntries = nil
        cacheLock.unlock()
    }

    var entries: [LegacyHistoryEntry] {
        cacheLock.lock()
        if let cached = cachedEntries {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let decoded: [LegacyHistoryEntry]
        if
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyHistoryEntry].self, from: data)
        {
            decoded = entries.sorted { $0.dateRead > $1.dateRead }
        } else {
            decoded = []
        }

        cacheLock.lock()
        cachedEntries = decoded
        cacheLock.unlock()
        return decoded
    }

    func update(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        pageIndex: Int,
        pageCount: Int
    ) {
        let key = "\(source.key)::\(manga.key)::\(chapter.key)"
        let currentEntries = entries
        var mergedManga = manga
        if let libraryManga = LegacyLibraryStore.shared.entry(sourceKey: source.key, mangaKey: manga.key)?.manga {
            mergedManga = libraryManga.mergedWithUpdate(mergedManga)
        }
        if let existingManga = currentEntries.first(where: { $0.sourceKey == source.key && $0.manga.key == manga.key })?.manga {
            mergedManga = existingManga.mergedWithUpdate(mergedManga)
        }
        var current = currentEntries.filter { $0.key != key }
        current.insert(
            LegacyHistoryEntry(
                sourceKey: source.key,
                sourceName: source.name,
                manga: mergedManga,
                chapter: chapter,
                pageIndex: max(0, pageIndex),
                pageCount: max(pageCount, 0),
                dateRead: Date()
            ),
            at: 0
        )
        save(Array(current.prefix(250)))
    }

    func remove(key: String) {
        save(entries.filter { $0.key != key })
    }

    func removeManga(sourceKey: String, mangaKey: String) {
        save(entries.filter { !($0.sourceKey == sourceKey && $0.manga.key == mangaKey) })
    }

    func latest(sourceKey: String, mangaKey: String) -> LegacyHistoryEntry? {
        return entries.first { $0.sourceKey == sourceKey && $0.manga.key == mangaKey }
    }

    /// Chapter keys for this manga that have been read to completion (last page),
    /// used to dim already-read chapters in the list.
    func readChapterKeys(sourceKey: String, mangaKey: String) -> Set<String> {
        var keys: Set<String> = []
        for entry in entries where entry.sourceKey == sourceKey && entry.manga.key == mangaKey {
            if entry.pageCount > 0, entry.pageIndex >= entry.pageCount - 1 {
                keys.insert(entry.chapter.key)
            }
        }
        return keys
    }

    func updateMangaMetadata(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = entries
        var didChange = false
        for index in current.indices where current[index].sourceKey == source.key && current[index].manga.key == manga.key {
            let mergedManga = current[index].manga.mergedWithUpdate(manga)
            if mergedManga != current[index].manga {
                current[index].manga = mergedManga
                current[index].sourceName = source.name
                didChange = true
            }
        }
        if didChange {
            save(current)
        }
    }

    func clear() {
        save([])
    }

    func replace(_ entries: [LegacyHistoryEntry]) {
        save(entries)
    }

    private func save(_ entries: [LegacyHistoryEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyHistoryDidChange, object: nil)
        }
    }
}

final class LegacyReaderSessionStore {
    static let shared = LegacyReaderSessionStore()

    private let defaultsKey = "AidokuLegacy.reader.lastSession"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var entry: LegacyHistoryEntry? {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entry = try? decoder.decode(LegacyHistoryEntry.self, from: data)
        else {
            return nil
        }
        return entry
    }

    func save(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        pageIndex: Int,
        pageCount: Int
    ) {
        let entry = LegacyHistoryEntry(
            sourceKey: source.key,
            sourceName: source.name,
            manga: manga,
            chapter: chapter,
            pageIndex: max(0, pageIndex),
            pageCount: max(pageCount, 0),
            dateRead: Date()
        )
        if let data = try? encoder.encode(entry) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Lightweight reading-statistics store backing the Insights screen.
///
/// Records one chapter-read event per chapter per calendar day. Persists a
/// per-day map of chapter keys (capped to the last year) plus an all-time
/// chapter total, all in UserDefaults. This is a deliberately small stand-in
/// for the modern app's Core Data `ReadingSession` analytics.
final class LegacyReadingStatsStore {
    static let shared = LegacyReadingStatsStore()

    private let dailyKey = "AidokuLegacy.stats.dailyChapters"
    private let totalKey = "AidokuLegacy.stats.totalChapters"
    private let maxDays = 366

    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Map of `yyyy-MM-dd` -> set of chapter keys read that day.
    private var dailyChapters: [String: [String]] {
        get {
            guard
                let data = UserDefaults.standard.data(forKey: dailyKey),
                let value = try? JSONDecoder().decode([String: [String]].self, from: data)
            else {
                return [:]
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: dailyKey)
            }
        }
    }

    /// All-time count of distinct chapter-read events (never decreases on prune).
    var totalChapters: Int {
        UserDefaults.standard.integer(forKey: totalKey)
    }

    func recordChapterRead(sourceKey: String, mangaKey: String, chapterKey: String) {
        let day = dayFormatter.string(from: Date())
        let chapterId = "\(sourceKey)::\(mangaKey)::\(chapterKey)"
        var map = dailyChapters
        var todays = map[day] ?? []
        guard !todays.contains(chapterId) else { return }
        todays.append(chapterId)
        map[day] = todays
        map = prune(map)
        dailyChapters = map
        UserDefaults.standard.set(totalChapters + 1, forKey: totalKey)
    }

    /// Number of chapters read on a given day.
    func count(on date: Date) -> Int {
        dailyChapters[dayFormatter.string(from: date)]?.count ?? 0
    }

    /// Days with at least one chapter read.
    var daysActive: Int {
        dailyChapters.values.filter { !$0.isEmpty }.count
    }

    /// Consecutive days read up to and including today.
    var currentStreak: Int {
        let calendar = Calendar(identifier: .gregorian)
        var streak = 0
        var day = Date()
        while count(on: day) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// Longest run of consecutive active days in the stored window.
    var longestStreak: Int {
        let calendar = Calendar(identifier: .gregorian)
        let activeDays = Set(dailyChapters.compactMap { $0.value.isEmpty ? nil : $0.key })
        guard !activeDays.isEmpty else { return 0 }
        var longest = 0
        for dayString in activeDays {
            guard let date = dayFormatter.date(from: dayString) else { continue }
            // Only start counting from the beginning of a run.
            if let prior = calendar.date(byAdding: .day, value: -1, to: date),
               activeDays.contains(dayFormatter.string(from: prior)) {
                continue
            }
            var run = 0
            var cursor = date
            while activeDays.contains(dayFormatter.string(from: cursor)) {
                run += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            longest = max(longest, run)
        }
        return longest
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: dailyKey)
        UserDefaults.standard.removeObject(forKey: totalKey)
    }

    private func prune(_ map: [String: [String]]) -> [String: [String]] {
        guard map.count > maxDays else { return map }
        let sortedKeys = map.keys.sorted(by: >)
        let keep = Set(sortedKeys.prefix(maxDays))
        return map.filter { keep.contains($0.key) }
    }
}

/// Contribution-style grid of daily reading activity. Oldest day at top-left,
/// today at bottom-right; column height is fixed at 7 days.
final class LegacyHeatmapView: UIView {
    private let spacing: CGFloat = 3
    private let rows = 7

    override func draw(_ rect: CGRect) {
        let square = floor((bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
        guard square > 0 else { return }
        let cols = max(1, Int((bounds.width + spacing) / (square + spacing)))
        let totalDays = cols * rows
        let calendar = Calendar(identifier: .gregorian)
        let store = LegacyReadingStatsStore.shared
        let today = Date()

        // Day at grid index 0 is the oldest shown; index totalDays-1 is today.
        for index in 0..<totalDays {
            let offset = -(totalDays - 1 - index)
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let count = store.count(on: date)
            let col = index / rows
            let row = index % rows
            let x = CGFloat(col) * (square + spacing)
            let y = CGFloat(row) * (square + spacing)
            let cellRect = CGRect(x: x, y: y, width: square, height: square)
            let path = UIBezierPath(roundedRect: cellRect, cornerRadius: 2)
            color(for: count).setFill()
            path.fill()
        }
    }

    private func color(for count: Int) -> UIColor {
        let accent = LegacyPalette.accent
        switch count {
            case 0: return LegacyPalette.primaryText.withAlphaComponent(0.08)
            case 1: return accent.withAlphaComponent(0.30)
            case 2...3: return accent.withAlphaComponent(0.55)
            case 4...6: return accent.withAlphaComponent(0.78)
            default: return accent
        }
    }
}

/// Reading statistics screen: summary stats + an activity heatmap, backed by
/// `LegacyReadingStatsStore`. A lightweight stand-in for the modern Insights UI.
final class LegacyInsightsViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let heatmap = LegacyHeatmapView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reading Insights"
        view.backgroundColor = LegacyPalette.background

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        rebuild()
    }

    private func rebuild() {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let store = LegacyReadingStatsStore.shared
        if store.totalChapters == 0 {
            stack.addArrangedSubview(makeEmptyLabel())
            return
        }

        stack.addArrangedSubview(makeStatsGrid(store: store))
        stack.addArrangedSubview(makeHeatmapCard())
        stack.addArrangedSubview(makeClearButton())
    }

    private func makeEmptyLabel() -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = LegacyPalette.secondaryText
        label.font = UIFont.systemFont(ofSize: 15)
        label.text = "No reading activity yet.\nRead a chapter to start tracking insights."
        return label
    }

    private func makeStatsGrid(store: LegacyReadingStatsStore) -> UIView {
        let items: [(String, String)] = [
            ("\(store.totalChapters)", "Chapters Read"),
            ("\(store.daysActive)", "Days Active"),
            ("\(store.currentStreak)", "Current Streak"),
            ("\(store.longestStreak)", "Longest Streak")
        ]
        // Two cards per row.
        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.distribution = .fillEqually
        topRow.spacing = 12
        topRow.addArrangedSubview(makeStatCard(value: items[0].0, label: items[0].1))
        topRow.addArrangedSubview(makeStatCard(value: items[1].0, label: items[1].1))

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 12
        bottomRow.addArrangedSubview(makeStatCard(value: items[2].0, label: items[2].1))
        bottomRow.addArrangedSubview(makeStatCard(value: items[3].0, label: items[3].1))

        let container = UIStackView(arrangedSubviews: [topRow, bottomRow])
        container.axis = .vertical
        container.spacing = 12
        return container
    }

    private func makeStatCard(value: String, label: String) -> UIView {
        let card = UIView()
        card.backgroundColor = LegacyPalette.panel
        card.layer.cornerRadius = 12

        let valueLabel = UILabel()
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        valueLabel.textColor = LegacyPalette.primaryText
        valueLabel.text = value

        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = UIFont.systemFont(ofSize: 13)
        nameLabel.textColor = LegacyPalette.secondaryText
        nameLabel.text = label

        card.addSubview(valueLabel)
        card.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            nameLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            nameLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    private func makeHeatmapCard() -> UIView {
        let card = UIView()
        card.backgroundColor = LegacyPalette.panel
        card.layer.cornerRadius = 12

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = LegacyPalette.secondaryText
        titleLabel.text = "ACTIVITY"

        heatmap.translatesAutoresizingMaskIntoConstraints = false
        heatmap.backgroundColor = .clear
        heatmap.isOpaque = false
        heatmap.contentMode = .redraw

        card.addSubview(titleLabel)
        card.addSubview(heatmap)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            heatmap.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            heatmap.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            heatmap.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            heatmap.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            heatmap.heightAnchor.constraint(equalToConstant: 110)
        ])
        return card
    }

    private func makeClearButton() -> UIView {
        let button = UIButton(type: .system)
        button.setTitle("Clear Statistics", for: .normal)
        button.setTitleColor(UIColor.systemRed, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        button.addTarget(self, action: #selector(confirmClear), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(
            title: "Clear Statistics",
            message: "Remove all reading insights data? This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            LegacyReadingStatsStore.shared.clear()
            self?.rebuild()
        })
        present(alert, animated: true)
    }
}

struct LegacyUpdateEntry: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
    var dateFound: Date

    var key: String {
        return "\(sourceKey)::\(manga.key)::\(chapter.key)"
    }
}

final class LegacyUpdateStore {
    static let shared = LegacyUpdateStore()

    private let defaultsKey = "AidokuLegacy.updates.entries"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    var entries: [LegacyUpdateEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let entries = try? decoder.decode([LegacyUpdateEntry].self, from: data)
        else {
            return []
        }
        return entries.sorted { $0.dateFound > $1.dateFound }
    }

    func add(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga, chapters: [AidokuRunnerLegacyChapter]) {
        guard !chapters.isEmpty else { return }
        var current = entries
        let now = Date()
        for chapter in chapters {
            let entry = LegacyUpdateEntry(
                sourceKey: source.key,
                sourceName: source.name,
                manga: manga,
                chapter: chapter,
                dateFound: now
            )
            current.removeAll { $0.key == entry.key }
            current.insert(entry, at: 0)
        }
        save(Array(current.prefix(500)))
    }

    func updateMangaMetadata(manga: AidokuRunnerLegacyManga, source: AidokuRunnerLegacySource) {
        var current = entries
        var didChange = false
        for index in current.indices where current[index].sourceKey == source.key && current[index].manga.key == manga.key {
            let mergedManga = current[index].manga.mergedWithUpdate(manga)
            if mergedManga != current[index].manga {
                current[index].manga = mergedManga
                current[index].sourceName = source.name
                didChange = true
            }
        }
        if didChange {
            save(current)
        }
    }

    func remove(key: String) {
        save(entries.filter { $0.key != key })
    }

    func remove(sourceKey: String, mangaKey: String) {
        save(entries.filter { !($0.sourceKey == sourceKey && $0.manga.key == mangaKey) })
    }

    func clear() {
        save([])
    }

    func replace(_ entries: [LegacyUpdateEntry]) {
        save(entries)
    }

    private func save(_ entries: [LegacyUpdateEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .legacyUpdatesDidChange, object: nil)
        }
    }
}

enum LegacyMangaMigrationMode: Equatable {
    case copy
    case migrate
}

enum LegacyMangaMigrationEngine {
    static func apply(
        fromSource: AidokuRunnerLegacySource,
        fromManga: AidokuRunnerLegacyManga,
        toSource: AidokuRunnerLegacySource,
        toManga: AidokuRunnerLegacyManga,
        mode: LegacyMangaMigrationMode,
        now: Date = Date()
    ) {
        let normalizedTargetManga = normalizedManga(toManga, sourceKey: toSource.key)
        let shouldKeepOriginal = mode == .copy

        LegacyLibraryStore.shared.replace(migratedLibraryEntries(
            current: LegacyLibraryStore.shared.rawEntries,
            fromSourceKey: fromSource.key,
            fromMangaKey: fromManga.key,
            toSource: toSource,
            toManga: normalizedTargetManga,
            keepOriginal: shouldKeepOriginal,
            now: now
        ))
        LegacyHistoryStore.shared.replace(migratedHistoryEntries(
            current: LegacyHistoryStore.shared.entries,
            fromSourceKey: fromSource.key,
            fromMangaKey: fromManga.key,
            toSource: toSource,
            toManga: normalizedTargetManga,
            keepOriginal: shouldKeepOriginal
        ))
        LegacyUpdateStore.shared.replace(migratedUpdateEntries(
            current: LegacyUpdateStore.shared.entries,
            fromSourceKey: fromSource.key,
            fromMangaKey: fromManga.key,
            toSource: toSource,
            toManga: normalizedTargetManga,
            keepOriginal: shouldKeepOriginal
        ))
        LegacyTrackerStore.shared.replace(migratedTrackEntries(
            current: LegacyTrackerStore.shared.entries,
            fromSourceKey: fromSource.key,
            fromMangaKey: fromManga.key,
            toSourceKey: toSource.key,
            toMangaKey: normalizedTargetManga.key,
            keepOriginal: shouldKeepOriginal
        ))
    }

    static func migratedLibraryEntries(
        current: [LegacyLibraryEntry],
        fromSourceKey: String,
        fromMangaKey: String,
        toSource: AidokuRunnerLegacySource,
        toManga: AidokuRunnerLegacyManga,
        keepOriginal: Bool,
        now: Date
    ) -> [LegacyLibraryEntry] {
        let sourceEntry = current.first { $0.sourceKey == fromSourceKey && $0.manga.key == fromMangaKey }
        let categories = sourceEntry?.displayCategories ?? LegacyCategoryStore.shared.defaultCategoriesForNewEntry()
        var next = current.filter {
            !($0.sourceKey == toSource.key && $0.manga.key == toManga.key)
                && (keepOriginal || !($0.sourceKey == fromSourceKey && $0.manga.key == fromMangaKey))
        }
        next.insert(
            LegacyLibraryEntry(
                sourceKey: toSource.key,
                sourceName: toSource.name,
                manga: normalizedManga(toManga, sourceKey: toSource.key),
                dateAdded: sourceEntry?.dateAdded ?? now,
                category: categories.first,
                categories: categories
            ),
            at: 0
        )
        return next
    }

    static func migratedHistoryEntries(
        current: [LegacyHistoryEntry],
        fromSourceKey: String,
        fromMangaKey: String,
        toSource: AidokuRunnerLegacySource,
        toManga: AidokuRunnerLegacyManga,
        keepOriginal: Bool
    ) -> [LegacyHistoryEntry] {
        let targetManga = normalizedManga(toManga, sourceKey: toSource.key)
        let targetChapters = targetManga.chapters ?? []
        let matching = current.filter { $0.sourceKey == fromSourceKey && $0.manga.key == fromMangaKey }
        var next = current.filter {
            !($0.sourceKey == toSource.key && $0.manga.key == targetManga.key)
                && (keepOriginal || !($0.sourceKey == fromSourceKey && $0.manga.key == fromMangaKey))
        }
        let migrated = matching.map { entry -> LegacyHistoryEntry in
            LegacyHistoryEntry(
                sourceKey: toSource.key,
                sourceName: toSource.name,
                manga: targetManga,
                chapter: bestMatchingChapter(for: entry.chapter, in: targetChapters),
                pageIndex: entry.pageIndex,
                pageCount: entry.pageCount,
                dateRead: entry.dateRead
            )
        }
        next.insert(contentsOf: migrated, at: 0)
        return next
    }

    static func migratedUpdateEntries(
        current: [LegacyUpdateEntry],
        fromSourceKey: String,
        fromMangaKey: String,
        toSource: AidokuRunnerLegacySource,
        toManga: AidokuRunnerLegacyManga,
        keepOriginal: Bool
    ) -> [LegacyUpdateEntry] {
        let targetManga = normalizedManga(toManga, sourceKey: toSource.key)
        let targetChapters = targetManga.chapters ?? []
        let matching = current.filter { $0.sourceKey == fromSourceKey && $0.manga.key == fromMangaKey }
        var next = current.filter {
            !($0.sourceKey == toSource.key && $0.manga.key == targetManga.key)
                && (keepOriginal || !($0.sourceKey == fromSourceKey && $0.manga.key == fromMangaKey))
        }
        let migrated = matching.map { entry -> LegacyUpdateEntry in
            LegacyUpdateEntry(
                sourceKey: toSource.key,
                sourceName: toSource.name,
                manga: targetManga,
                chapter: bestMatchingChapter(for: entry.chapter, in: targetChapters),
                dateFound: entry.dateFound
            )
        }
        next.insert(contentsOf: migrated, at: 0)
        return next
    }

    static func migratedTrackEntries(
        current: [LegacyTrackEntry],
        fromSourceKey: String,
        fromMangaKey: String,
        toSourceKey: String,
        toMangaKey: String,
        keepOriginal: Bool
    ) -> [LegacyTrackEntry] {
        let matching = current.filter { $0.sourceKey == fromSourceKey && $0.mangaKey == fromMangaKey }
        let migratedTrackerIds = Set(matching.map { $0.trackerId })
        var next = current.filter {
            !(migratedTrackerIds.contains($0.trackerId) && $0.sourceKey == toSourceKey && $0.mangaKey == toMangaKey)
                && (keepOriginal || !($0.sourceKey == fromSourceKey && $0.mangaKey == fromMangaKey))
        }
        let migrated = matching.map { entry -> LegacyTrackEntry in
            var updated = entry
            updated.sourceKey = toSourceKey
            updated.mangaKey = toMangaKey
            return updated
        }
        next.insert(contentsOf: migrated, at: 0)
        return next
    }

    private static func normalizedManga(_ manga: AidokuRunnerLegacyManga, sourceKey: String) -> AidokuRunnerLegacyManga {
        var target = manga
        target.sourceKey = sourceKey
        return target
    }

    private static func bestMatchingChapter(
        for chapter: AidokuRunnerLegacyChapter,
        in candidates: [AidokuRunnerLegacyChapter]
    ) -> AidokuRunnerLegacyChapter {
        guard !candidates.isEmpty else { return chapter }
        if let match = candidates.first(where: { $0.key == chapter.key }) {
            return match
        }
        if let chapterNumber = chapter.chapterNumber,
           let match = candidates.first(where: { $0.chapterNumber == chapterNumber }) {
            return match
        }
        let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let title = title, !title.isEmpty,
           let match = candidates.first(where: {
               $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
           }) {
            return match
        }
        return chapter
    }
}

struct LegacyDownloadedChapter: Codable, Hashable {
    var sourceKey: String
    var sourceName: String
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
    var pageCount: Int
    var byteCount: Int64
    var dateDownloaded: Date

    var key: String {
        return "\(sourceKey)::\(manga.key)::\(chapter.key)"
    }
}

private struct LegacyDownloadedPageRecord: Codable {
    enum Kind: String, Codable {
        case image
        case text
    }

    var kind: Kind
    var fileName: String?
    var text: String?
    var description: String?
}

private struct LegacyDownloadedChapterManifest: Codable {
    var chapter: LegacyDownloadedChapter
    var pages: [LegacyDownloadedPageRecord]
}

private enum LegacyDownloadAutomationDefaults {
    static let deleteAfterReading = "AidokuLegacy.downloads.deleteAfterReading"
    static let downloadNextUnreadAfterReading = "AidokuLegacy.downloads.downloadNextUnreadAfterReading"
}

func aidokuLegacyDownloadsDeleteAfterReading() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyDownloadAutomationDefaults.deleteAfterReading)
}

func aidokuLegacySetDownloadsDeleteAfterReading(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyDownloadAutomationDefaults.deleteAfterReading)
}

func aidokuLegacyDownloadsDownloadNextUnreadAfterReading() -> Bool {
    return UserDefaults.standard.bool(forKey: LegacyDownloadAutomationDefaults.downloadNextUnreadAfterReading)
}

func aidokuLegacySetDownloadsDownloadNextUnreadAfterReading(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: LegacyDownloadAutomationDefaults.downloadNextUnreadAfterReading)
}

final class LegacyDownloadStore {
    static let shared = LegacyDownloadStore()

    private let fileManager = FileManager.default
    private let manifestFileName = "manifest.json"

    var downloadedChapters: [LegacyDownloadedChapter] {
        guard
            let root = try? downloadsDirectory(),
            let manifests = try? fileManager.subpathsOfDirectory(atPath: root.path)
        else {
            return []
        }
        return manifests
            .filter { $0.hasSuffix(manifestFileName) }
            .compactMap { relativePath -> LegacyDownloadedChapter? in
                let url = root.appendingPathComponent(relativePath)
                guard
                    let data = try? Data(contentsOf: url),
                    let manifest = try? JSONDecoder().decode(LegacyDownloadedChapterManifest.self, from: data)
                else {
                    return nil
                }
                return manifest.chapter
            }
            .sorted { $0.dateDownloaded > $1.dateDownloaded }
    }

    func hasChapter(sourceKey: String, mangaKey: String, chapterKey: String) -> Bool {
        let directory = chapterDirectory(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
        return fileManager.fileExists(atPath: directory.appendingPathComponent(manifestFileName).path)
    }

    /// Whether any chapter of the manga has been downloaded.
    func hasDownloads(sourceKey: String, mangaKey: String) -> Bool {
        let root = (try? downloadsDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let mangaDirectory = root
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(sourceKey), isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(mangaKey), isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: mangaDirectory.path)) ?? []
        return !contents.isEmpty
    }

    func pages(sourceKey: String, mangaKey: String, chapterKey: String) -> [AidokuRunnerLegacyPage]? {
        let directory = chapterDirectory(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(LegacyDownloadedChapterManifest.self, from: data)
        else {
            return nil
        }
        let pages: [AidokuRunnerLegacyPage] = manifest.pages.compactMap { record in
            switch record.kind {
                case .text:
                    return AidokuRunnerLegacyPage(
                        content: .text(record.text ?? ""),
                        hasDescription: !(record.description ?? "").isEmpty,
                        description: record.description
                    )
                case .image:
                    guard
                        let fileName = record.fileName
                    else {
                        return nil
                    }
                    return AidokuRunnerLegacyPage(
                        content: .url(directory.appendingPathComponent(fileName), context: nil),
                        hasDescription: !(record.description ?? "").isEmpty,
                        description: record.description
                    )
            }
        }
        return pages.count == manifest.pages.count ? pages : nil
    }

    func makeWriter(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        pageCount: Int
    ) throws -> LegacyDownloadWriter {
        return try LegacyDownloadWriter(
            store: self,
            source: source,
            manga: manga,
            chapter: chapter,
            pageCount: pageCount
        )
    }

    func delete(_ chapter: LegacyDownloadedChapter) {
        let directory = chapterDirectory(sourceKey: chapter.sourceKey, mangaKey: chapter.manga.key, chapterKey: chapter.chapter.key)
        try? fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
    }

    func delete(sourceKey: String, mangaKey: String, chapterKey: String) {
        let directory = chapterDirectory(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
        try? fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
    }

    func clear() {
        if let directory = try? downloadsDirectory() {
            try? fileManager.removeItem(at: directory)
        }
        NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
    }

    fileprivate func downloadsDirectory() throws -> URL {
        let directory = try aidokuLegacyApplicationSupportDirectory()
            .appendingPathComponent("AidokuLegacyDownloads", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    fileprivate func chapterDirectory(sourceKey: String, mangaKey: String, chapterKey: String) -> URL {
        let root = (try? downloadsDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(sourceKey), isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(mangaKey), isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(chapterKey), isDirectory: true)
    }

    final class LegacyDownloadWriter {
        private let store: LegacyDownloadStore
        private let fileManager = FileManager.default
        private let finalDirectory: URL
        private let tempDirectory: URL
        private let chapterInfo: LegacyDownloadedChapter
        private var records: [LegacyDownloadedPageRecord] = []
        private var byteCount: Int64 = 0

        fileprivate init(
            store: LegacyDownloadStore,
            source: AidokuRunnerLegacySource,
            manga: AidokuRunnerLegacyManga,
            chapter: AidokuRunnerLegacyChapter,
            pageCount: Int
        ) throws {
            self.store = store
            finalDirectory = store.chapterDirectory(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key)
            tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AidokuLegacyDownload-\(UUID().uuidString)", isDirectory: true)
            chapterInfo = LegacyDownloadedChapter(
                sourceKey: source.key,
                sourceName: source.name,
                manga: manga,
                chapter: chapter,
                pageCount: pageCount,
                byteCount: 0,
                dateDownloaded: Date()
            )
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        func writeImageData(_ data: Data, index: Int, description: String?) throws {
            let fileName = String(format: "%04d.img", index)
            try data.write(to: tempDirectory.appendingPathComponent(fileName), options: .atomic)
            byteCount += Int64(data.count)
            records.append(LegacyDownloadedPageRecord(kind: .image, fileName: fileName, text: nil, description: description))
        }

        func writeText(_ text: String, description: String?) {
            records.append(LegacyDownloadedPageRecord(kind: .text, fileName: nil, text: text, description: description))
            byteCount += Int64(text.utf8.count)
        }

        func finish() throws -> LegacyDownloadedChapter {
            var finishedChapter = chapterInfo
            finishedChapter.byteCount = byteCount
            finishedChapter.pageCount = records.count
            let manifest = LegacyDownloadedChapterManifest(chapter: finishedChapter, pages: records)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: tempDirectory.appendingPathComponent(store.manifestFileName), options: .atomic)
            try? fileManager.removeItem(at: finalDirectory)
            try fileManager.createDirectory(at: finalDirectory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try fileManager.moveItem(at: tempDirectory, to: finalDirectory)
            NotificationCenter.default.post(name: .legacyDownloadsDidChange, object: nil)
            return finishedChapter
        }

        func cancel() {
            try? fileManager.removeItem(at: tempDirectory)
        }
    }
}

final class LegacyDownloadManager {
    static let shared = LegacyDownloadManager()

    private init() {}

    private enum DownloadPageRequest {
        case request(URLRequest)
        case localFile(URL)
    }

    func download(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        if LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            let existing = LegacyDownloadStore.shared.downloadedChapters.first {
                $0.sourceKey == source.key && $0.manga.key == manga.key && $0.chapter.key == chapter.key
            }
            if let existing = existing {
                completion(.success(existing))
                return
            }
        }
        source.runner.getPageList(manga: manga, chapter: chapter) { result in
            switch result {
                case .success(let rawPages):
                    guard !rawPages.isEmpty else {
                        completion(.failure(NSError(domain: "AidokuLegacy", code: 2, userInfo: [NSLocalizedDescriptionKey: "No pages to download."])))
                        return
                    }
                    LegacyZipPageResolver.shared.resolve(rawPages, source: source) { pages in
                        do {
                            let writer = try LegacyDownloadStore.shared.makeWriter(
                                source: source,
                                manga: manga,
                                chapter: chapter,
                                pageCount: pages.count
                            )
                            self.downloadPage(
                                pages: pages,
                                index: 0,
                                source: source,
                                writer: writer,
                                progress: progress,
                                completion: completion
                            )
                        } catch {
                            completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    private func downloadPage(
        pages: [AidokuRunnerLegacyPage],
        index: Int,
        source: AidokuRunnerLegacySource,
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        guard pages.indices.contains(index) else {
            do {
                completion(.success(try writer.finish()))
            } catch {
                writer.cancel()
                completion(.failure(error))
            }
            return
        }
        autoreleasepool {
            let page = pages[index]
            progress(index + 1, pages.count)
            aidokuLegacyResolvePageDescription(for: page, runner: source.runner) { pageDescription in
                self.downloadResolvedPage(
                    page,
                    pageDescription: pageDescription,
                    pageIndex: index,
                    pages: pages,
                    source: source,
                    writer: writer,
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    private func downloadResolvedPage(
        _ page: AidokuRunnerLegacyPage,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        source: AidokuRunnerLegacySource,
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        switch page.content {
            case .image(let data):
                do {
                    try writer.writeImageData(data, index: pageIndex, description: pageDescription)
                    self.downloadPage(pages: pages, index: pageIndex + 1, source: source, writer: writer, progress: progress, completion: completion)
                } catch {
                    writer.cancel()
                    completion(.failure(error))
                }
            case .text(let text):
                writer.writeText(text, description: pageDescription)
                self.downloadPage(pages: pages, index: pageIndex + 1, source: source, writer: writer, progress: progress, completion: completion)
            case .zipFile(_, _):
                writer.writeText("ZIP pages are not supported in the legacy downloader yet.", description: pageDescription)
                self.downloadPage(pages: pages, index: pageIndex + 1, source: source, writer: writer, progress: progress, completion: completion)
            case .url(let url, let context):
                if url.isFileURL {
                    self.fetchDownloadedPage(
                        request: .localFile(url),
                        context: context,
                        source: source,
                        pageDescription: pageDescription,
                        pageIndex: pageIndex,
                        pages: pages,
                        writer: writer,
                        progress: progress,
                        completion: completion
                    )
                    return
                }
                source.runner.getImageRequest(url: url, context: context) { result in
                    let pageRequest: URLRequest
                    switch result {
                        case .success(let imageRequest):
                            pageRequest = imageRequest.urlRequest(source: source, fallbackURL: url)
                        case .failure:
                            pageRequest = legacyFallbackImageRequest(url: url, source: source)
                    }
                    self.fetchDownloadedPage(
                        request: .request(pageRequest),
                        context: context,
                        source: source,
                        pageDescription: pageDescription,
                        pageIndex: pageIndex,
                        pages: pages,
                        writer: writer,
                        progress: progress,
                        completion: completion
                    )
                }
        }
    }

    private func fetchDownloadedPage(
        request: DownloadPageRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        switch request {
            case .localFile(let url):
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = try? Data(contentsOf: url)
                    guard let data = data, !data.isEmpty else {
                        writer.cancel()
                        completion(.failure(NSError(domain: "AidokuLegacy", code: 4, userInfo: [NSLocalizedDescriptionKey: "Downloaded page \(pageIndex + 1) is missing."])))
                        return
                    }
                    self.writeDownloadedPageData(
                        data,
                        pageDescription: pageDescription,
                        pageIndex: pageIndex,
                        pages: pages,
                        source: source,
                        writer: writer,
                        progress: progress,
                        completion: completion
                    )
                }
                return
            case .request(let urlRequest):
                fetchRemoteDownloadedPage(
                    request: urlRequest,
                    context: context,
                    source: source,
                    pageDescription: pageDescription,
                    pageIndex: pageIndex,
                    pages: pages,
                    writer: writer,
                    progress: progress,
                    completion: completion
                )
        }
    }

    private func fetchRemoteDownloadedPage(
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        aidokuLegacyReaderImageSession.dataTask(with: request) { data, response, error in
            if let error = error {
                writer.cancel()
                completion(.failure(error))
                return
            }
            guard
                let data = data,
                !data.isEmpty,
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                writer.cancel()
                completion(.failure(NSError(domain: "AidokuLegacy", code: 3, userInfo: [NSLocalizedDescriptionKey: "Page \(pageIndex + 1) failed to download."])))
                return
            }
            if source.runner.features.processesPages {
                source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { result in
                    let outputData: Data
                    if case .success(let image?) = result {
                        let maxHeight = aidokuLegacyReaderMaxPixelHeight()
                        let preparedImage = autoreleasepool {
                            LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                        }
                        outputData = preparedImage.jpegData(compressionQuality: 0.92) ?? preparedImage.pngData() ?? data
                    } else {
                        outputData = data
                    }
                    self.writeDownloadedPageData(
                        outputData,
                        pageDescription: pageDescription,
                        pageIndex: pageIndex,
                        pages: pages,
                        source: source,
                        writer: writer,
                        progress: progress,
                        completion: completion
                    )
                }
            } else {
                self.writeDownloadedPageData(
                    data,
                    pageDescription: pageDescription,
                    pageIndex: pageIndex,
                    pages: pages,
                    source: source,
                    writer: writer,
                    progress: progress,
                    completion: completion
                )
            }
        }.resume()
    }

    private func writeDownloadedPageData(
        _ data: Data,
        pageDescription: String?,
        pageIndex: Int,
        pages: [AidokuRunnerLegacyPage],
        source: AidokuRunnerLegacySource,
        writer: LegacyDownloadStore.LegacyDownloadWriter,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<LegacyDownloadedChapter, Error>) -> Void
    ) {
        do {
            try writer.writeImageData(data, index: pageIndex, description: pageDescription)
            self.downloadPage(pages: pages, index: pageIndex + 1, source: source, writer: writer, progress: progress, completion: completion)
        } catch {
            writer.cancel()
            completion(.failure(error))
        }
    }
}

final class LegacyDownloadAutomation {
    static let shared = LegacyDownloadAutomation()

    private var inFlightDownloadKeys = Set<String>()

    private init() {}

    func chapterDidComplete(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        nextUnreadChapter: AidokuRunnerLegacyChapter?
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.chapterDidComplete(
                    source: source,
                    manga: manga,
                    chapter: chapter,
                    nextUnreadChapter: nextUnreadChapter
                )
            }
            return
        }

        if aidokuLegacyDownloadsDeleteAfterReading(),
           LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            LegacyDownloadStore.shared.delete(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key)
        }

        guard aidokuLegacyDownloadsDownloadNextUnreadAfterReading(), let next = nextUnreadChapter else { return }
        guard !LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: next.key) else { return }
        let key = "\(source.key)::\(manga.key)::\(next.key)"
        guard !inFlightDownloadKeys.contains(key) else { return }
        inFlightDownloadKeys.insert(key)

        LegacyDownloadManager.shared.download(
            source: source,
            manga: manga,
            chapter: next,
            progress: { _, _ in },
            completion: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.inFlightDownloadKeys.remove(key)
                }
            }
        )
    }
}

private struct LegacyBackupFile: Codable {
    var version: Int
    var createdAt: Date
    var library: [LegacyLibraryEntry]
    var history: [LegacyHistoryEntry]
    var updates: [LegacyUpdateEntry]
    var repositories: [String]
    var filterGroups: [LegacyLibraryFilterGroup]
    var settings: [LegacyBackupSetting]

    init(
        version: Int,
        createdAt: Date,
        library: [LegacyLibraryEntry],
        history: [LegacyHistoryEntry],
        updates: [LegacyUpdateEntry],
        repositories: [String],
        filterGroups: [LegacyLibraryFilterGroup],
        settings: [LegacyBackupSetting]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.library = library
        self.history = history
        self.updates = updates
        self.repositories = repositories
        self.filterGroups = filterGroups
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        library = try container.decode([LegacyLibraryEntry].self, forKey: .library)
        history = try container.decode([LegacyHistoryEntry].self, forKey: .history)
        updates = try container.decode([LegacyUpdateEntry].self, forKey: .updates)
        repositories = try container.decode([String].self, forKey: .repositories)
        filterGroups = try container.decodeIfPresent([LegacyLibraryFilterGroup].self, forKey: .filterGroups) ?? []
        settings = try container.decode([LegacyBackupSetting].self, forKey: .settings)
    }
}

private struct LegacyBackupSetting: Codable {
    var key: String
    var boolValue: Bool?
    var intValue: Int?
    var doubleValue: Double?
    var stringValue: String?
    var stringArrayValue: [String]?
}

final class LegacyBackupManager {
    static let shared = LegacyBackupManager()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func createBackup() throws -> URL {
        let backup = LegacyBackupFile(
            version: 1,
            createdAt: Date(),
            library: LegacyLibraryStore.shared.rawEntries,
            history: LegacyHistoryStore.shared.entries,
            updates: LegacyUpdateStore.shared.entries,
            repositories: LegacySourceRepositoryStore.shared.repositoryURLs.map { $0.absoluteString },
            filterGroups: LegacyLibraryFilterGroupStore.shared.groups,
            settings: collectSettings()
        )
        let directory = try backupDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("AidokuLegacy-\(formatter.string(from: Date())).json")
        try encoder.encode(backup).write(to: url, options: .atomic)
        return url
    }

    func restore(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let backup = try decoder.decode(LegacyBackupFile.self, from: data)
        LegacyLibraryStore.shared.replace(backup.library)
        LegacyHistoryStore.shared.replace(backup.history)
        LegacyUpdateStore.shared.replace(backup.updates)
        LegacySourceRepositoryStore.shared.replace(with: backup.repositories.compactMap(URL.init(string:)))
        LegacyLibraryFilterGroupStore.shared.replace(backup.filterGroups)
        applySettings(backup.settings)
    }

    func backupURLs() -> [URL] {
        guard
            let directory = try? backupDirectory(),
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return lhsDate > rhsDate
            }
    }

    private func backupDirectory() throws -> URL {
        let directory = try aidokuLegacyApplicationSupportDirectory()
            .appendingPathComponent("AidokuLegacyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func collectSettings() -> [LegacyBackupSetting] {
        return UserDefaults.standard.dictionaryRepresentation().compactMap { key, value in
            guard shouldBackupSetting(key: key) else { return nil }
            if let value = value as? Bool {
                return LegacyBackupSetting(key: key, boolValue: value, intValue: nil, doubleValue: nil, stringValue: nil, stringArrayValue: nil)
            }
            if let value = value as? Int {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: value, doubleValue: nil, stringValue: nil, stringArrayValue: nil)
            }
            if let value = value as? Double {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: nil, doubleValue: value, stringValue: nil, stringArrayValue: nil)
            }
            if let value = value as? String {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: nil, doubleValue: nil, stringValue: value, stringArrayValue: nil)
            }
            if let value = value as? [String] {
                return LegacyBackupSetting(key: key, boolValue: nil, intValue: nil, doubleValue: nil, stringValue: nil, stringArrayValue: value)
            }
            return nil
        }
    }

    private func shouldBackupSetting(key: String) -> Bool {
        if key == "AidokuLegacy.library.entries" || key == "AidokuLegacy.history.entries" || key == "AidokuLegacy.updates.entries" {
            return false
        }
        if key.hasPrefix("AidokuLegacy.") {
            return true
        }
        return key.hasSuffix(".languages") || key.hasSuffix(".language") || key.hasSuffix(".url")
    }

    private func applySettings(_ settings: [LegacyBackupSetting]) {
        for setting in settings {
            if let value = setting.boolValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.intValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.doubleValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.stringValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            } else if let value = setting.stringArrayValue {
                UserDefaults.standard.set(value, forKey: setting.key)
            }
        }
        NotificationCenter.default.post(name: .legacyAppearanceDidChange, object: nil)
        NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
    }
}

final class LegacyImageLoader {
    static let shared = LegacyImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var memoryObserver: NSObjectProtocol?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 25
        configuration.httpMaximumConnectionsPerHost = aidokuLegacyIsLowMemoryMode() ? 1 : 3
        configuration.urlCache = URLCache(
            memoryCapacity: aidokuLegacyIsLowMemoryMode() ? 128 * 1024 : 6 * 1024 * 1024,
            diskCapacity: aidokuLegacyIsLowMemoryMode() ? 4 * 1024 * 1024 : 48 * 1024 * 1024,
            diskPath: "AidokuLegacyCoverImageCache"
        )
        configuration.httpAdditionalHeaders = [
            "Accept": aidokuLegacyImageAcceptHeader,
            "User-Agent": aidokuLegacyImageUserAgent
        ]
        session = URLSession(configuration: configuration)
        cache.countLimit = aidokuLegacyIsLowMemoryMode() ? 8 : 120
        cache.totalCostLimit = aidokuLegacyIsLowMemoryMode() ? 1024 * 1024 : 28 * 1024 * 1024
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clear()
        }
    }

    func clear() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func removeCachedImage(for url: URL, source: AidokuRunnerLegacySource? = nil) {
        cache.removeObject(forKey: url as NSURL)
        let requests = [legacyFallbackImageRequest(url: url, source: source)]
            + legacyFallbackImageRequests(url: url, source: source)
        for request in requests {
            session.configuration.urlCache?.removeCachedResponse(for: request)
        }
    }

    func removeCachedImages(for urls: [URL], source: AidokuRunnerLegacySource? = nil) {
        for url in urls {
            removeCachedImage(for: url, source: source)
        }
    }

    @discardableResult
    func load(
        url: URL,
        source: AidokuRunnerLegacySource? = nil,
        targetHeight: CGFloat = 220,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return nil
        }

        if url.isFileURL {
            loadLocalFile(url: url, cacheKey: key, targetHeight: targetHeight, completion: completion)
            return nil
        }

        if let source = source {
            source.runner.getImageRequest(url: url, context: nil) { [weak self] result in
                let request: URLRequest
                switch result {
                    case .success(let imageRequest):
                        request = imageRequest.urlRequest(source: source, fallbackURL: url)
                    case .failure:
                        request = legacyFallbackImageRequest(url: url, source: source)
                }
                self?.load(
                    request: request,
                    cacheKey: key,
                    targetHeight: targetHeight,
                    forceDownsample: true,
                    fallbackRequests: legacyFallbackImageRequests(url: url, source: source, excluding: request),
                    completion: completion
                )
            }
            return nil
        }

        return load(
            request: legacyFallbackImageRequest(url: url),
            cacheKey: key,
            targetHeight: targetHeight,
            forceDownsample: true,
            fallbackRequests: legacyFallbackImageRequests(url: url, source: nil),
            completion: completion
        )
    }

    @discardableResult
    func loadCover(
        urls: [URL],
        source: AidokuRunnerLegacySource,
        targetHeight: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask? {
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            if !result.contains(url) {
                result.append(url)
            }
        }
        guard let firstURL = uniqueURLs.first else {
            completion(nil)
            return nil
        }
        let cacheKey = firstURL as NSURL
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return nil
        }
        if firstURL.isFileURL {
            loadLocalFile(url: firstURL, cacheKey: cacheKey, targetHeight: targetHeight, completion: completion)
            return nil
        }

        let fallbackRequests = uniqueURLs.flatMap { legacyFallbackImageRequests(url: $0, source: source) }
        source.runner.getImageRequest(url: firstURL, context: nil) { [weak self] result in
            let request: URLRequest
            switch result {
                case .success(let imageRequest):
                    request = imageRequest.urlRequest(source: source, fallbackURL: firstURL)
                case .failure:
                    request = legacyFallbackImageRequest(url: firstURL, source: source)
            }
            self?.load(
                request: request,
                cacheKey: cacheKey,
                targetHeight: targetHeight,
                forceDownsample: true,
                fallbackRequests: fallbackRequests.filter { !legacyImageRequestsMatch($0, request) },
                completion: completion
            )
        }
        return nil
    }

    private func loadLocalFile(
        url: URL,
        cacheKey key: NSURL,
        targetHeight: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let image = (try? Data(contentsOf: url)).flatMap { data -> UIImage? in
                return autoreleasepool {
                    self?.makeImage(
                        from: data,
                        maxPixelHeight: targetHeight * UIScreen.main.scale,
                        forceDownsample: true
                    )
                }
            }
            if let image = image {
                self?.store(image, forKey: key)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    @discardableResult
    private func load(
        request: URLRequest,
        cacheKey key: NSURL,
        targetHeight: CGFloat,
        forceDownsample: Bool,
        fallbackRequests: [URLRequest] = [],
        retriesRemaining: Int = 1,
        completion: @escaping (UIImage?) -> Void
    ) -> URLSessionDataTask? {
        // iOS 12 URLSession caps at TLS 1.2, so TLS-1.3-only hosts (notably
        // uploads.mangadex.org, which serves MangaDex covers) can't be fetched
        // through it and the image stays blank. Route those through the OpenSSL
        // client, mirroring the WASM source request path. The OpenSSL fetch is
        // blocking, so run it off the main thread; it returns no data task.
        if request.url?.scheme?.lowercased() == "https",
           LegacyTLS13Hosts.shared.contains(request.url?.host) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (data, response, _) = LegacyHTTPSClient.send(request)
                self?.handleImageResponse(
                    data: data,
                    response: response,
                    request: request,
                    cacheKey: key,
                    targetHeight: targetHeight,
                    forceDownsample: forceDownsample,
                    fallbackRequests: fallbackRequests,
                    retriesRemaining: retriesRemaining,
                    completion: completion
                )
            }
            return nil
        }

        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            self?.handleImageResponse(
                data: data,
                response: response,
                request: request,
                cacheKey: key,
                targetHeight: targetHeight,
                forceDownsample: forceDownsample,
                fallbackRequests: fallbackRequests,
                retriesRemaining: retriesRemaining,
                completion: completion
            )
        }
        task.resume()
        return task
    }

    private func handleImageResponse(
        data: Data?,
        response: URLResponse?,
        request: URLRequest,
        cacheKey key: NSURL,
        targetHeight: CGFloat,
        forceDownsample: Bool,
        fallbackRequests: [URLRequest],
        retriesRemaining: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        let image = data.flatMap { data -> UIImage? in
            if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
                return nil
            }
            return autoreleasepool {
                makeImage(
                    from: data,
                    maxPixelHeight: targetHeight * UIScreen.main.scale,
                    forceDownsample: forceDownsample
                )
            }
        }
        if image == nil, let fallbackRequest = fallbackRequests.first {
            session.configuration.urlCache?.removeCachedResponse(for: request)
            let remainingFallbackRequests = Array(fallbackRequests.dropFirst())
            load(
                request: fallbackRequest,
                cacheKey: key,
                targetHeight: targetHeight,
                forceDownsample: forceDownsample,
                fallbackRequests: remainingFallbackRequests,
                retriesRemaining: retriesRemaining,
                completion: completion
            )
            return
        }
        if image == nil, retriesRemaining > 0 {
            session.configuration.urlCache?.removeCachedResponse(for: request)
            var retryRequest = request
            retryRequest.cachePolicy = .reloadIgnoringLocalCacheData
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.load(
                    request: retryRequest,
                    cacheKey: key,
                    targetHeight: targetHeight,
                    forceDownsample: forceDownsample,
                    fallbackRequests: [],
                    retriesRemaining: retriesRemaining - 1,
                    completion: completion
                )
            }
            return
        }
        if let image = image {
            store(image, forKey: key)
        } else {
            session.configuration.urlCache?.removeCachedResponse(for: request)
        }
        DispatchQueue.main.async {
            completion(image)
        }
    }

    private func store(_ image: UIImage, forKey key: NSURL) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        let costLimit = aidokuLegacyIsLowMemoryMode() ? CGFloat(1024 * 1024) : CGFloat(16 * 1024 * 1024)
        cache.setObject(image, forKey: key, cost: max(1, Int(min(pixels, costLimit))))
    }

    func makeImage(from data: Data, maxPixelHeight: CGFloat, forceDownsample: Bool = false) -> UIImage? {
        if isAVIF(data) {
            return makeAVIFImage(from: data, maxPixelHeight: maxPixelHeight, forceDownsample: forceDownsample)
        }
        if isWebP(data) {
            return makeWebPImage(from: data, maxPixelHeight: maxPixelHeight, forceDownsample: forceDownsample)
        }

        guard forceDownsample || UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
            return UIImage(data: data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(800, Int(maxPixelHeight))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    func preparedImage(_ image: UIImage, maxPixelHeight: CGFloat) -> UIImage {
        let limit = max(800, maxPixelHeight)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelHeight > limit, pixelWidth > 0 else {
            return image
        }
        let scale = limit / pixelHeight
        let targetSize = CGSize(width: max(1, pixelWidth * scale), height: limit)
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return scaledImage ?? image
    }

    private func makeWebPImage(from data: Data, maxPixelHeight: CGFloat, forceDownsample: Bool) -> UIImage? {
        guard forceDownsample || UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
            return SDImageWebPCoder.shared.decodedImage(with: data, options: nil)
        }
        let maxPixelSize = max(800, Int(maxPixelHeight))
        return SDImageWebPCoder.shared.decodedImage(
            with: data,
            options: [.decodeThumbnailPixelSize: CGSize(width: maxPixelSize, height: maxPixelSize)]
        )
    }

    private func makeAVIFImage(from data: Data, maxPixelHeight: CGFloat, forceDownsample: Bool) -> UIImage? {
        guard forceDownsample || UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages") else {
            return AVIFDecoder.decode(data)
        }
        let maxPixelSize = max(800, Int(maxPixelHeight))
        return AVIFDecoder.decode(
            data,
            sampleSize: CGSize(width: maxPixelSize, height: maxPixelSize)
        )
    }

    private func isAVIF(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(32))
        guard
            bytes.count >= 12,
            bytes[4] == 0x66, // f
            bytes[5] == 0x74, // t
            bytes[6] == 0x79, // y
            bytes[7] == 0x70  // p
        else {
            return false
        }
        var index = 8
        while index + 3 < bytes.count {
            if
                bytes[index] == 0x61, // a
                bytes[index + 1] == 0x76, // v
                bytes[index + 2] == 0x69, // i
                (bytes[index + 3] == 0x66 || bytes[index + 3] == 0x73) // f or s
            {
                return true
            }
            index += 4
        }
        return false
    }

    private func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        return bytes[0] == 0x52
            && bytes[1] == 0x49
            && bytes[2] == 0x46
            && bytes[3] == 0x46
            && bytes[8] == 0x57
            && bytes[9] == 0x45
            && bytes[10] == 0x42
            && bytes[11] == 0x50
    }

    static func placeholder(size: CGSize = CGSize(width: 44, height: 62)) -> UIImage {
        let rect = CGRect(origin: .zero, size: size)
        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        LegacyPalette.background.setFill()
        UIRectFill(rect)
        LegacyPalette.accent.withAlphaComponent(0.22).setFill()
        UIBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 5), cornerRadius: 4).fill()
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
}

/// A label that draws its text with padding, used for the unread-count badge
/// drawn over library covers (iOS 12 has no SF Symbols / padded badge view).
final class LegacyLibraryBadgeLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero { didSet { invalidateIntrinsicContentSize() } }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}

/// Shared interface for the grid and list cells so cover loading can target
/// either one.
protocol LegacyLibraryCoverCell: AnyObject {
    var entryKey: String? { get set }
    var coverImageView: UIImageView { get }
}

/// Mihon-style library grid cell: cover fills the cell, the title is overlaid
/// at the bottom over a dark gradient, and an unread-count badge sits top-left.
final class LegacyLibraryGridCell: UICollectionViewCell, LegacyLibraryCoverCell {
    static let reuseID = "LibraryGridCell"

    let imageView = UIImageView()
    var entryKey: String?
    var coverImageView: UIImageView { imageView }

    private let titleLabel = UILabel()
    private let gradientLayer = CAGradientLayer()
    private let badgeLabel = LegacyLibraryBadgeLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 6
        contentView.backgroundColor = LegacyPalette.panel

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = LegacyPalette.panel
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        gradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.75).cgColor
        ]
        gradientLayer.locations = [0.45, 1]
        imageView.layer.addSublayer(gradientLayer)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        badgeLabel.font = .systemFont(ofSize: 12, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = LegacyPalette.accent
        badgeLabel.layer.cornerRadius = 4
        badgeLabel.clipsToBounds = true
        badgeLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            badgeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            badgeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = imageView.bounds
    }

    func configure(title: String, unread: Int) {
        titleLabel.text = title
        if unread > 0 {
            badgeLabel.text = "\(unread)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        entryKey = nil
        badgeLabel.isHidden = true
    }
}

/// Compact list row: small cover thumbnail on the left, title (and source)
/// in the middle, unread-count badge on the right.
final class LegacyLibraryListCell: UICollectionViewCell, LegacyLibraryCoverCell {
    static let reuseID = "LibraryListCell"

    let imageView = UIImageView()
    var entryKey: String?
    var coverImageView: UIImageView { imageView }

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let badgeLabel = LegacyLibraryBadgeLabel()
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = LegacyPalette.panel
        contentView.layer.cornerRadius = 6
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = LegacyPalette.background
        imageView.layer.cornerRadius = 4
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = LegacyPalette.primaryText
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = LegacyPalette.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        badgeLabel.font = .systemFont(ofSize: 12, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = LegacyPalette.accent
        badgeLabel.layer.cornerRadius = 4
        badgeLabel.clipsToBounds = true
        badgeLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        badgeLabel.isHidden = true
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeLabel)

        separator.backgroundColor = LegacyPalette.secondaryText.withAlphaComponent(0.15)
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: CGFloat(2) / CGFloat(3)),

            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: badgeLabel.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: badgeLabel.leadingAnchor, constant: -8),

            badgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            badgeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String, unread: Int) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        if unread > 0 {
            badgeLabel.text = "\(unread)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        entryKey = nil
        badgeLabel.isHidden = true
    }
}

final class LegacyLibraryViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private let searchController = UISearchController(searchResultsController: nil)
    private let automaticUpdateDefaultsKey = "AidokuLegacy.library.automaticUpdates"
    private let lastAutomaticUpdateDefaultsKey = "AidokuLegacy.library.lastAutomaticUpdate"
    private var entries: [LegacyLibraryEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var libraryObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var isUpdatingLibrary = false
    private var updateNewChapterCount = 0
    private var updateNewMangaCount = 0
    private var activeCategory: String?
    private var activeFilterGroup: LegacyLibraryFilterGroup?
    private var sortOption = LegacyLibrarySortOption.current
    private var pendingCoverRepairs = Set<String>()
    private var coverRepairAttempts: [String: Int] = [:]

    private var collectionView: UICollectionView!
    private let flowLayout = UICollectionViewFlowLayout()
    private var displayMode = LegacyLibraryDisplayMode.current
    private let gridRefreshControl = UIRefreshControl()
    private let emptyLabel = UILabel()

    // Category tab bar (hidden when there are no categories).
    private let tabScrollView = UIScrollView()
    private let tabStack = UIStackView()
    private let tabIndicator = UIView()
    private var tabTitles: [String] = []
    private var tabHeightConstraint: NSLayoutConstraint!
    private var tabIndicatorLeading: NSLayoutConstraint?
    private var tabIndicatorWidth: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = LegacyPalette.background
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search library"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Updates", style: .plain, target: self, action: #selector(openUpdates))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Sort", style: .plain, target: self, action: #selector(showLibraryOptions)),
            UIBarButtonItem(title: "Update", style: .plain, target: self, action: #selector(updateLibraryManually))
        ]

        setupTabBar()
        setupCollectionView()

        libraryObserver = NotificationCenter.default.addObserver(
            forName: .legacyLibraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isUpdatingLibrary else { return }
            self.reloadData()
        }
        sourceObserver = NotificationCenter.default.addObserver(
            forName: .legacyInstalledSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateLibraryIfNeeded()
    }

    deinit {
        if let libraryObserver = libraryObserver {
            NotificationCenter.default.removeObserver(libraryObserver)
        }
        if let sourceObserver = sourceObserver {
            NotificationCenter.default.removeObserver(sourceObserver)
        }
    }

    private var currentSortKey: String {
        if activeFilterGroup != nil { return LegacyCategoryStore.allKey }
        if let category = activeCategory {
            return category.isEmpty ? LegacyCategoryStore.uncategorizedKey : category
        }
        return LegacyCategoryStore.allKey
    }

    @objc private func reloadData() {
        let query = searchController.searchBar.text
        sortOption = LegacyCategoryStore.shared.sort(forKey: currentSortKey)
        entries = LegacyLibraryStore.shared.entries(
            category: activeFilterGroup == nil ? activeCategory : nil,
            filterGroup: activeFilterGroup,
            query: query,
            sort: sortOption
        )
        sources = packageInstaller.loadInstalledSources()
        if let activeFilterGroup = activeFilterGroup {
            title = activeFilterGroup.name
        } else {
            title = "Library"
        }
        rebuildTabs()
        gridRefreshControl.endRefreshing()
        emptyLabel.isHidden = !entries.isEmpty
        collectionView.reloadData()
    }

    // MARK: - Collection view

    private func setupCollectionView() {
        flowLayout.minimumInteritemSpacing = 10
        flowLayout.minimumLineSpacing = displayMode == .grid ? 14 : 8
        flowLayout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = LegacyPalette.background
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(LegacyLibraryGridCell.self, forCellWithReuseIdentifier: LegacyLibraryGridCell.reuseID)
        collectionView.register(LegacyLibraryListCell.self, forCellWithReuseIdentifier: LegacyLibraryListCell.reuseID)
        collectionView.refreshControl = gridRefreshControl
        gridRefreshControl.addTarget(self, action: #selector(updateLibraryManually), for: .valueChanged)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        collectionView.addGestureRecognizer(longPress)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: tabScrollView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = LegacyPalette.secondaryText
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.text = "No manga in Library.\nOpen Sources, browse manga, then tap Add."
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return entries.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let entry = entries[indexPath.item]
        let unread = unreadCount(for: entry)
        switch displayMode {
            case .grid:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LegacyLibraryGridCell.reuseID,
                    for: indexPath
                ) as! LegacyLibraryGridCell
                cell.entryKey = entry.key
                cell.configure(title: entry.manga.title, unread: unread)
                loadCover(for: entry, into: cell)
                return cell
            case .list:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LegacyLibraryListCell.reuseID,
                    for: indexPath
                ) as! LegacyLibraryListCell
                cell.entryKey = entry.key
                cell.configure(title: entry.manga.title, subtitle: entry.sourceName, unread: unread)
                loadCover(for: entry, into: cell)
                return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.item) else { return }
        let entry = entries[indexPath.item]
        guard let source = source(for: entry) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to open this manga.")
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entry.manga),
            animated: true
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        switch displayMode {
            case .grid:
                let columns: CGFloat = 3
                let insets: CGFloat = 12 * 2
                let spacing: CGFloat = 10 * (columns - 1)
                let available = collectionView.bounds.width - insets - spacing
                let width = max(floor(available / columns), 1)
                return CGSize(width: width, height: width * 1.5)
            case .list:
                let width = max(collectionView.bounds.width - 12 * 2, 1)
                return CGSize(width: width, height: 84)
        }
    }

    private func applyDisplayMode() {
        flowLayout.minimumLineSpacing = displayMode == .grid ? 14 : 8
        flowLayout.invalidateLayout()
        collectionView.reloadData()
    }

    private func unreadCount(for entry: LegacyLibraryEntry) -> Int {
        guard let chapters = entry.manga.chapters, !chapters.isEmpty else { return 0 }
        let readKeys = LegacyHistoryStore.shared.readChapterKeys(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
        return chapters.filter { !$0.locked && !readKeys.contains($0.key) }.count
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard
            let indexPath = collectionView.indexPathForItem(at: point),
            entries.indices.contains(indexPath.item)
        else { return }
        let entry = entries[indexPath.item]
        let alert = UIAlertController(title: entry.manga.title, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Categories", style: .default) { [weak self] _ in
            self?.showCategoriesPrompt(for: entry)
        })
        alert.addAction(UIAlertAction(title: "Remove from Library", style: .destructive) { _ in
            LegacyLibraryStore.shared.remove(sourceKey: entry.sourceKey, mangaKey: entry.manga.key)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = collectionView
            popover.sourceRect = CGRect(origin: point, size: .zero)
        }
        present(alert, animated: true)
    }

    // MARK: - Category tabs

    private func setupTabBar() {
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.backgroundColor = LegacyPalette.background
        view.addSubview(tabScrollView)

        tabStack.axis = .horizontal
        tabStack.alignment = .fill
        tabStack.spacing = 18
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.addSubview(tabStack)

        tabIndicator.backgroundColor = LegacyPalette.accent
        tabIndicator.layer.cornerRadius = 1
        tabIndicator.isHidden = true
        tabIndicator.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.addSubview(tabIndicator)

        tabHeightConstraint = tabScrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabHeightConstraint,

            tabStack.topAnchor.constraint(equalTo: tabScrollView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScrollView.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabScrollView.leadingAnchor, constant: 16),
            tabStack.trailingAnchor.constraint(equalTo: tabScrollView.trailingAnchor, constant: -16),
            tabStack.heightAnchor.constraint(equalTo: tabScrollView.heightAnchor),

            tabIndicator.heightAnchor.constraint(equalToConstant: 2),
            tabIndicator.bottomAnchor.constraint(equalTo: tabScrollView.bottomAnchor)
        ])
    }

    private func rebuildTabs() {
        let categories = LegacyCategoryStore.shared.allCategories()
        let titles = categories.isEmpty ? [] : (["All"] + categories)
        if titles != tabTitles {
            tabTitles = titles
            tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, label) in titles.enumerated() {
                let button = UIButton(type: .system)
                button.setTitle(label, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
                button.tag = index
                button.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)
                tabStack.addArrangedSubview(button)
            }
        }
        tabHeightConstraint.constant = titles.isEmpty ? 0 : 44
        tabScrollView.isHidden = titles.isEmpty
        updateTabSelection()
    }

    private var selectedTabIndex: Int? {
        guard !tabTitles.isEmpty, activeFilterGroup == nil else { return nil }
        guard let category = activeCategory, !category.isEmpty else { return 0 }
        return tabTitles.firstIndex { $0.caseInsensitiveCompare(category) == .orderedSame }
    }

    @objc private func selectTab(_ sender: UIButton) {
        let index = sender.tag
        activeFilterGroup = nil
        if index == 0 {
            activeCategory = nil
        } else if tabTitles.indices.contains(index) {
            activeCategory = tabTitles[index]
        }
        reloadData()
    }

    private func updateTabSelection() {
        let selected = selectedTabIndex
        for case let button as UIButton in tabStack.arrangedSubviews {
            let isSelected = button.tag == selected
            button.setTitleColor(isSelected ? LegacyPalette.accent : LegacyPalette.secondaryText, for: .normal)
        }
        tabIndicatorLeading?.isActive = false
        tabIndicatorWidth?.isActive = false
        guard
            let selected = selected,
            let button = tabStack.arrangedSubviews.first(where: { ($0 as? UIButton)?.tag == selected })
        else {
            tabIndicator.isHidden = true
            return
        }
        tabIndicator.isHidden = false
        let leading = tabIndicator.leadingAnchor.constraint(equalTo: button.leadingAnchor)
        let width = tabIndicator.widthAnchor.constraint(equalTo: button.widthAnchor)
        tabIndicatorLeading = leading
        tabIndicatorWidth = width
        NSLayoutConstraint.activate([leading, width])
    }

    private func source(for entry: LegacyLibraryEntry) -> AidokuRunnerLegacySource? {
        return sources.first { $0.key == entry.sourceKey }
    }

    private func loadCover(for entry: LegacyLibraryEntry, into cell: LegacyLibraryCoverCell) {
        cell.coverImageView.image = nil
        guard let source = source(for: entry) else { return }
        let coverURLs = entry.manga.coverURLCandidates(relativeTo: source.urls.first)
        guard !coverURLs.isEmpty else {
            repairCover(for: entry, source: source)
            return
        }
        let entryKey = entry.key
        LegacyImageLoader.shared.loadCover(
            urls: coverURLs,
            source: source,
            targetHeight: 360
        ) { [weak self, weak cell] image in
            guard let self = self, let cell = cell, cell.entryKey == entryKey else { return }
            cell.coverImageView.image = image
            if image == nil {
                LegacyImageLoader.shared.removeCachedImages(for: coverURLs, source: source)
                self.repairCover(for: entry, source: source)
            } else {
                self.coverRepairAttempts[entryKey] = nil
            }
        }
    }

    private func repairCover(for entry: LegacyLibraryEntry, source: AidokuRunnerLegacySource) {
        let attempts = coverRepairAttempts[entry.key] ?? 0
        guard attempts < 4 else { return }
        guard !pendingCoverRepairs.contains(entry.key) else { return }
        coverRepairAttempts[entry.key] = attempts + 1
        pendingCoverRepairs.insert(entry.key)
        let oldCoverURL = entry.manga.coverURL(relativeTo: source.urls.first)
        source.runner.getMangaUpdate(manga: entry.manga, needsDetails: true, needsChapters: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingCoverRepairs.remove(entry.key)
                guard case .success(let updatedManga) = result else { return }
                let mergedManga = entry.manga.mergedWithUpdate(updatedManga)
                guard !mergedManga.coverURLCandidates(relativeTo: source.urls.first).isEmpty else {
                    self.repairCoverWithAlternateCovers(for: entry, source: source, oldCoverURL: oldCoverURL)
                    return
                }
                if let oldCoverURL = oldCoverURL {
                    LegacyImageLoader.shared.removeCachedImage(for: oldCoverURL, source: source)
                }
                LegacyImageLoader.shared.removeCachedImages(for: mergedManga.coverURLCandidates(relativeTo: source.urls.first), source: source)
                LegacyLibraryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                self.reloadVisibleLibraryEntry(with: entry.key)
            }
        }
    }

    private func repairCoverWithAlternateCovers(
        for entry: LegacyLibraryEntry,
        source: AidokuRunnerLegacySource,
        oldCoverURL: URL?
    ) {
        guard source.runner.features.providesAlternateCovers else { return }
        source.runner.getAlternateCovers(manga: entry.manga) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard case .success(let covers) = result else { return }
                let cover = covers
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                guard let cover = cover else { return }
                var manga = entry.manga
                manga.cover = cover
                guard !manga.coverURLCandidates(relativeTo: source.urls.first).isEmpty else { return }
                if let oldCoverURL = oldCoverURL {
                    LegacyImageLoader.shared.removeCachedImage(for: oldCoverURL, source: source)
                }
                LegacyImageLoader.shared.removeCachedImages(for: manga.coverURLCandidates(relativeTo: source.urls.first), source: source)
                LegacyLibraryStore.shared.updateMangaMetadata(manga: manga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: manga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: manga, source: source)
                self.reloadVisibleLibraryEntry(with: entry.key)
            }
        }
    }

    private func reloadVisibleLibraryEntry(with key: String) {
        guard let row = entries.firstIndex(where: { $0.key == key }) else { return }
        guard let refreshedEntry = LegacyLibraryStore.shared.entry(sourceKey: entries[row].sourceKey, mangaKey: entries[row].manga.key) else {
            reloadData()
            return
        }
        entries[row] = refreshedEntry
        let indexPath = IndexPath(item: row, section: 0)
        guard collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        collectionView.reloadItems(at: [indexPath])
    }

    @objc private func openUpdates() {
        navigationController?.pushViewController(LegacyUpdatesViewController(), animated: true)
    }

    @objc private func showLibraryOptions() {
        let sortScope: String
        if activeFilterGroup != nil {
            sortScope = "All"
        } else if let category = activeCategory {
            sortScope = category.isEmpty ? "Uncategorized" : category
        } else {
            sortScope = "All"
        }
        let alert = UIAlertController(title: "Library", message: "Sort applies to: \(sortScope)", preferredStyle: .actionSheet)
        let nextMode: LegacyLibraryDisplayMode = displayMode == .grid ? .list : .grid
        alert.addAction(UIAlertAction(
            title: displayMode == .grid ? "View: Grid (switch to List)" : "View: List (switch to Grid)",
            style: .default
        ) { [weak self] _ in
            guard let self = self else { return }
            self.displayMode = nextMode
            LegacyLibraryDisplayMode.setCurrent(nextMode)
            self.applyDisplayMode()
        })
        for option in LegacyLibrarySortOption.allCases {
            let title = option == sortOption ? "Sort: \(option.title) (Current)" : "Sort: \(option.title)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                LegacyCategoryStore.shared.setSort(option, forKey: self.currentSortKey)
                self.sortOption = option
                self.reloadData()
            })
        }
        let filtersTitle = LegacyLibraryStatusFilterStore.hasActiveFilters ? "Filters… (Active)" : "Filters…"
        alert.addAction(UIAlertAction(title: filtersTitle, style: .default) { [weak self] _ in
            self?.showLibraryFilters()
        })
        alert.addAction(UIAlertAction(title: activeCategory == nil ? "All Categories (Current)" : "All Categories", style: .default) { [weak self] _ in
            self?.activeFilterGroup = nil
            self?.activeCategory = nil
            self?.reloadData()
        })
        alert.addAction(UIAlertAction(title: activeCategory == "" ? "Uncategorized (Current)" : "Uncategorized", style: .default) { [weak self] _ in
            self?.activeFilterGroup = nil
            self?.activeCategory = ""
            self?.reloadData()
        })
        for category in LegacyCategoryStore.shared.allCategories() {
            let title = activeFilterGroup == nil && activeCategory == category ? "\(category) (Current)" : category
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.activeFilterGroup = nil
                self?.activeCategory = category
                self?.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Manage Categories", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(LegacyCategoryManagerViewController(), animated: true)
        })
        let filterGroups = LegacyLibraryFilterGroupStore.shared.groups
        for group in filterGroups {
            let title = activeFilterGroup?.id == group.id ? "Filter: \(group.name) (Current)" : "Filter: \(group.name)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.activeCategory = nil
                self?.activeFilterGroup = group
                self?.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Create Filter Group", style: .default) { [weak self] _ in
            self?.showFilterGroupPrompt()
        })
        if let activeFilterGroup = activeFilterGroup {
            alert.addAction(UIAlertAction(title: "Delete Current Filter Group", style: .destructive) { [weak self] _ in
                LegacyLibraryFilterGroupStore.shared.remove(id: activeFilterGroup.id)
                self?.activeFilterGroup = nil
                self?.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alert, animated: true)
    }

    private func showLibraryFilters() {
        let alert = UIAlertController(
            title: "Library Filters",
            message: "Tap to cycle: off → include → exclude.",
            preferredStyle: .actionSheet
        )
        for filter in LegacyLibraryStatusFilter.allCases {
            let state = LegacyLibraryStatusFilterStore.state(filter)
            alert.addAction(UIAlertAction(title: "\(filter.title)\(state.indicator)", style: .default) { [weak self] _ in
                LegacyLibraryStatusFilterStore.setState(state.next, for: filter)
                self?.reloadData()
                // Re-present so multiple filters can be set in one pass.
                self?.showLibraryFilters()
            })
        }
        if LegacyLibraryStatusFilterStore.hasActiveFilters {
            alert.addAction(UIAlertAction(title: "Clear Filters", style: .destructive) { [weak self] _ in
                LegacyLibraryStatusFilterStore.clearAll()
                self?.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alert, animated: true)
    }

    private func showCategoriesPrompt(for entry: LegacyLibraryEntry) {
        let alert = UIAlertController(title: "Set Categories", message: entry.manga.title, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Reading, Favorites"
            textField.text = entry.displayCategories.joined(separator: ", ")
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyLibraryStore.shared.setCategories(sourceKey: entry.sourceKey, mangaKey: entry.manga.key, categories: [])
        })
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            let categories = aidokuLegacySplitList(alert?.textFields?.first?.text)
            for category in categories {
                LegacyCategoryStore.shared.add(category)
            }
            LegacyLibraryStore.shared.setCategories(
                sourceKey: entry.sourceKey,
                mangaKey: entry.manga.key,
                categories: categories
            )
        })
        present(alert, animated: true)
    }

    private func showFilterGroupPrompt() {
        let alert = UIAlertController(
            title: "Create Filter Group",
            message: "Match manga by categories and tags. Separate values with commas.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "Group name"
            textField.autocapitalizationType = .words
        }
        alert.addTextField { textField in
            textField.placeholder = "Categories"
            textField.autocapitalizationType = .words
        }
        alert.addTextField { textField in
            textField.placeholder = "Tags"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save Match Any", style: .default) { [weak self, weak alert] _ in
            self?.saveFilterGroup(from: alert, matchAll: false)
        })
        alert.addAction(UIAlertAction(title: "Save Match All", style: .default) { [weak self, weak alert] _ in
            self?.saveFilterGroup(from: alert, matchAll: true)
        })
        present(alert, animated: true)
    }

    private func saveFilterGroup(from alert: UIAlertController?, matchAll: Bool) {
        let name = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        let group = LegacyLibraryFilterGroup(
            id: UUID().uuidString,
            name: name,
            categories: LegacyLibraryEntry.normalizedList(aidokuLegacySplitList(alert?.textFields?[1].text)),
            tags: LegacyLibraryEntry.normalizedList(aidokuLegacySplitList(alert?.textFields?[2].text)),
            matchAll: matchAll
        )
        LegacyLibraryFilterGroupStore.shared.save(group)
        activeCategory = nil
        activeFilterGroup = group
        reloadData()
    }

    @objc private func updateLibraryManually() {
        startLibraryUpdate(automatic: false)
    }

    private func updateLibraryIfNeeded() {
        guard UserDefaults.standard.bool(forKey: automaticUpdateDefaultsKey), !isUpdatingLibrary else { return }
        guard !LegacyLibraryStore.shared.rawEntries.isEmpty else { return }
        let now = Date()
        if
            let lastUpdate = UserDefaults.standard.object(forKey: lastAutomaticUpdateDefaultsKey) as? Date,
            now.timeIntervalSince(lastUpdate) < 15 * 60
        {
            return
        }
        UserDefaults.standard.set(now, forKey: lastAutomaticUpdateDefaultsKey)
        startLibraryUpdate(automatic: true)
    }

    func performBackgroundFetchUpdate(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard UserDefaults.standard.bool(forKey: automaticUpdateDefaultsKey) else {
            completion(.noData)
            return
        }
        guard !LegacyLibraryStore.shared.rawEntries.isEmpty else {
            completion(.noData)
            return
        }
        let now = Date()
        if
            let lastUpdate = UserDefaults.standard.object(forKey: lastAutomaticUpdateDefaultsKey) as? Date,
            now.timeIntervalSince(lastUpdate) < 15 * 60
        {
            completion(.noData)
            return
        }
        UserDefaults.standard.set(now, forKey: lastAutomaticUpdateDefaultsKey)
        startLibraryUpdate(automatic: true) { _, newChapterCount in
            completion(newChapterCount > 0 ? .newData : .noData)
        }
    }

    private func startLibraryUpdate(
        automatic: Bool,
        completion: ((Int, Int) -> Void)? = nil
    ) {
        guard !isUpdatingLibrary else {
            completion?(0, 0)
            return
        }
        let allEntries = LegacyLibraryStore.shared.rawEntries
        let updateItems = allEntries.compactMap { entry -> (LegacyLibraryEntry, AidokuRunnerLegacySource)? in
            guard let source = sources.first(where: { $0.key == entry.sourceKey }) else { return nil }
            return (entry, source)
        }
        let items = automatic && aidokuLegacyIsLowMemoryMode() ? Array(updateItems.prefix(25)) : updateItems
        guard !items.isEmpty else {
            gridRefreshControl.endRefreshing()
            completion?(0, 0)
            return
        }
        isUpdatingLibrary = true
        updateNewChapterCount = 0
        updateNewMangaCount = 0
        navigationItem.prompt = automatic ? "Updating library..." : "Updating \(items.count) manga..."
        updateLibraryItems(items, index: 0, automatic: automatic, completion: completion)
    }

    private func updateLibraryItems(
        _ items: [(LegacyLibraryEntry, AidokuRunnerLegacySource)],
        index: Int,
        automatic: Bool,
        completion: ((Int, Int) -> Void)? = nil
    ) {
        guard index < items.count else {
            isUpdatingLibrary = false
            navigationItem.prompt = nil
            gridRefreshControl.endRefreshing()
            reloadData()
            LegacyUpdateNotificationManager.shared.notifyLibraryUpdateSummary(
                updatedMangaCount: updateNewMangaCount,
                totalNewChapters: updateNewChapterCount
            )
            if !automatic {
                showAlert(title: "Library Updated", message: "Finished checking \(items.count) manga.")
            }
            completion?(updateNewMangaCount, updateNewChapterCount)
            return
        }
        navigationItem.prompt = "Updating \(index + 1) of \(items.count)..."
        let item = items[index]
        item.1.runner.getMangaUpdate(manga: item.0.manga, needsDetails: true, needsChapters: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .success(let manga) = result {
                    let mergedManga = item.0.manga.mergedWithUpdate(manga)
                    self.recordUpdates(oldManga: item.0.manga, newManga: mergedManga, source: item.1)
                    LegacyLibraryStore.shared.update(manga: mergedManga, source: item.1)
                    LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: item.1)
                    LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: item.1)
                }
                self.updateLibraryItems(items, index: index + 1, automatic: automatic, completion: completion)
            }
        }
    }

    private func recordUpdates(
        oldManga: AidokuRunnerLegacyManga,
        newManga: AidokuRunnerLegacyManga,
        source: AidokuRunnerLegacySource
    ) {
        guard
            let oldChapters = oldManga.chapters,
            !oldChapters.isEmpty,
            let newChapters = newManga.chapters
        else {
            return
        }
        let oldKeys = Set(oldChapters.map { $0.key })
        let addedChapters = newChapters.filter { !oldKeys.contains($0.key) && !$0.locked }
        guard !addedChapters.isEmpty else { return }
        LegacyUpdateStore.shared.add(source: source, manga: newManga, chapters: addedChapters)
        LegacyUpdateNotificationManager.shared.notifyNewChapters(
            mangaTitle: newManga.title,
            sourceKey: source.key,
            mangaKey: newManga.key,
            newChapterCount: addedChapters.count
        )
        updateNewChapterCount += addedChapters.count
        updateNewMangaCount += 1
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension LegacyLibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        reloadData()
    }
}

final class LegacyHistoryViewController: UITableViewController {
    private struct HistorySection {
        let title: String
        var entries: [LegacyHistoryEntry]
    }

    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var sectionsData: [HistorySection] = []
    private var isEmpty = true
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?
    private var pendingCoverRepairs = Set<String>()
    private var coverRepairAttempts: [String: Int] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "History"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadData), for: .valueChanged)
        observer = NotificationCenter.default.addObserver(
            forName: .legacyHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadData() {
        let all = Self.backfillCovers(LegacyHistoryStore.shared.entries)
        sectionsData = Self.groupByDay(all)
        isEmpty = all.isEmpty
        sources = packageInstaller.loadInstalledSources()
        refreshControl?.endRefreshing()
        tableView.reloadData()
    }

    // History stores one entry per chapter. The store sometimes drops the cover
    // on the latest entry (e.g. a source returned no artwork that read); reuse a
    // cover from another entry of the same manga so every row shows art.
    private static func backfillCovers(_ all: [LegacyHistoryEntry]) -> [LegacyHistoryEntry] {
        var coverByManga: [String: String] = [:]
        for entry in all {
            let key = "\(entry.sourceKey)::\(entry.manga.key)"
            if coverByManga[key] == nil, let cover = entry.manga.cover, !cover.isEmpty {
                coverByManga[key] = cover
            }
        }
        return all.map { entry in
            guard (entry.manga.cover ?? "").isEmpty else { return entry }
            let key = "\(entry.sourceKey)::\(entry.manga.key)"
            guard let cover = coverByManga[key] else { return entry }
            var copy = entry
            copy.manga.cover = cover
            return copy
        }
    }

    // Group newest-first entries into day buckets with Mihon-style headers
    // ("Today", "Yesterday", "N days ago", then an explicit date).
    private static func groupByDay(_ all: [LegacyHistoryEntry]) -> [HistorySection] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [LegacyHistoryEntry]] = [:]
        for entry in all {
            let day = calendar.startOfDay(for: entry.dateRead)
            if byDay[day] == nil {
                order.append(day)
                byDay[day] = []
            }
            byDay[day]?.append(entry)
        }
        return order.map { HistorySection(title: dayTitle(for: $0, calendar: calendar), entries: byDay[$0] ?? []) }
    }

    private static func dayTitle(for day: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: Date())
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch daysAgo {
        case ..<0: break
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(daysAgo) days ago"
        default: break
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy"
        return formatter.string(from: day)
    }

    private func entry(at indexPath: IndexPath) -> LegacyHistoryEntry? {
        guard sectionsData.indices.contains(indexPath.section) else { return nil }
        let entries = sectionsData[indexPath.section].entries
        guard entries.indices.contains(indexPath.row) else { return nil }
        return entries[indexPath.row]
    }

    private func indexPath(forKey key: String) -> IndexPath? {
        for (section, data) in sectionsData.enumerated() {
            if let row = data.entries.firstIndex(where: { $0.key == key }) {
                return IndexPath(row: row, section: section)
            }
        }
        return nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return isEmpty ? 1 : sectionsData.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !isEmpty else { return 1 }
        return sectionsData[section].entries.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !isEmpty, sectionsData.indices.contains(section) else { return nil }
        return sectionsData[section].title
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = LegacyPalette.secondaryText
        header.textLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        header.contentView.backgroundColor = LegacyPalette.background
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HistoryCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "HistoryCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 1

        guard let entry = entry(at: indexPath) else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "No reading history."
            cell.detailTextLabel?.text = "Open a chapter to start tracking progress."
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        loadCover(for: entry, into: cell, at: indexPath)
        cell.textLabel?.text = entry.manga.title
        cell.detailTextLabel?.text = historySubtitle(for: entry)
        cell.accessoryView = makeDeleteButton()
        cell.selectionStyle = .default
        if let cover = cell.imageView {
            cover.isUserInteractionEnabled = true
            if cover.gestureRecognizers?.isEmpty ?? true {
                cover.addGestureRecognizer(
                    UITapGestureRecognizer(target: self, action: #selector(handleCoverTap(_:)))
                )
            }
        }
        return cell
    }

    private func makeDeleteButton() -> UIButton {
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.setImage(Self.trashIcon(color: LegacyPalette.secondaryText), for: .normal)
        button.addTarget(self, action: #selector(handleDeleteTap(_:)), for: .touchUpInside)
        return button
    }

    @objc private func handleDeleteTap(_ sender: UIButton) {
        let point = sender.convert(CGPoint(x: sender.bounds.midX, y: sender.bounds.midY), to: tableView)
        guard
            let indexPath = tableView.indexPathForRow(at: point),
            let entry = entry(at: indexPath)
        else { return }
        LegacyHistoryStore.shared.remove(key: entry.key)
    }

    // SF Symbols are iOS 13+, so draw a simple trash glyph for iOS 12.
    private static func trashIcon(color: UIColor) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: 4, y: 6.5))
        path.addLine(to: CGPoint(x: 20, y: 6.5))
        path.move(to: CGPoint(x: 9, y: 6.5))
        path.addLine(to: CGPoint(x: 9, y: 4))
        path.addLine(to: CGPoint(x: 15, y: 4))
        path.addLine(to: CGPoint(x: 15, y: 6.5))
        path.move(to: CGPoint(x: 6, y: 6.5))
        path.addLine(to: CGPoint(x: 7, y: 20))
        path.addLine(to: CGPoint(x: 17, y: 20))
        path.addLine(to: CGPoint(x: 18, y: 6.5))
        path.move(to: CGPoint(x: 10, y: 9.5))
        path.addLine(to: CGPoint(x: 10.5, y: 17))
        path.move(to: CGPoint(x: 14, y: 9.5))
        path.addLine(to: CGPoint(x: 13.5, y: 17))
        path.stroke()
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image.withRenderingMode(.alwaysOriginal)
    }

    @objc private func handleCoverTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: tableView)
        guard
            let indexPath = tableView.indexPathForRow(at: location),
            let entry = entry(at: indexPath)
        else { return }
        guard let source = source(for: entry) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to view this manga.")
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entry.manga),
            animated: true
        )
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = entry(at: indexPath) else { return }
        guard let source = source(for: entry) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to resume this chapter.")
            return
        }
        navigationController?.pushViewController(
            LegacyReaderFactory.makeReader(
                source: source,
                manga: entry.manga,
                chapter: entry.chapter,
                initialPageIndex: entry.pageIndex
            ),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, let entry = entry(at: indexPath) else { return }
        LegacyHistoryStore.shared.remove(key: entry.key)
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard let entry = entry(at: indexPath) else { return nil }
        // Each row is one read chapter, so removing clears just that entry.
        let remove = UITableViewRowAction(style: .destructive, title: "Remove") { _, _ in
            LegacyHistoryStore.shared.remove(key: entry.key)
        }
        return [remove]
    }

    private func source(for entry: LegacyHistoryEntry) -> AidokuRunnerLegacySource? {
        return sources.first { $0.key == entry.sourceKey }
    }

    private func historySubtitle(for entry: LegacyHistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: entry.dateRead)
        let label: String
        if let number = entry.chapter.chapterNumber {
            label = "Ch. \(Self.formatChapterNumber(number))"
        } else {
            label = entry.chapter.legacyFormattedTitle
        }
        return "\(label) - \(time)"
    }

    private static func formatChapterNumber(_ number: Float) -> String {
        if number == number.rounded() {
            return String(Int(number))
        }
        return String(number)
    }

    private func loadCover(for entry: LegacyHistoryEntry, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let source = source(for: entry) else { return }
        let coverURLs = entry.manga.coverURLCandidates(relativeTo: source.urls.first)
        guard !coverURLs.isEmpty else {
            repairCover(for: entry, source: source)
            return
        }
        let entryKey = entry.key
        LegacyImageLoader.shared.loadCover(
            urls: coverURLs,
            source: source,
            targetHeight: 130
        ) { [weak self, weak cell] image in
            guard
                let self = self,
                let cell = cell,
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath,
                self.entry(at: indexPath)?.key == entryKey
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
            if image == nil {
                LegacyImageLoader.shared.removeCachedImages(for: coverURLs, source: source)
                self.repairCover(for: entry, source: source)
            } else {
                self.coverRepairAttempts[entryKey] = nil
            }
        }
    }

    private func repairCover(for entry: LegacyHistoryEntry, source: AidokuRunnerLegacySource) {
        let attempts = coverRepairAttempts[entry.key] ?? 0
        guard attempts < 4 else { return }
        guard !pendingCoverRepairs.contains(entry.key) else { return }
        coverRepairAttempts[entry.key] = attempts + 1
        pendingCoverRepairs.insert(entry.key)
        let oldCoverURL = entry.manga.coverURL(relativeTo: source.urls.first)
        source.runner.getMangaUpdate(manga: entry.manga, needsDetails: true, needsChapters: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingCoverRepairs.remove(entry.key)
                guard case .success(let updatedManga) = result else { return }
                let mergedManga = entry.manga.mergedWithUpdate(updatedManga)
                guard !mergedManga.coverURLCandidates(relativeTo: source.urls.first).isEmpty else {
                    self.repairCoverWithAlternateCovers(for: entry, source: source, oldCoverURL: oldCoverURL)
                    return
                }
                if let oldCoverURL = oldCoverURL {
                    LegacyImageLoader.shared.removeCachedImage(for: oldCoverURL, source: source)
                }
                LegacyImageLoader.shared.removeCachedImages(for: mergedManga.coverURLCandidates(relativeTo: source.urls.first), source: source)
                LegacyLibraryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                self.reloadVisibleHistoryEntry(with: entry.key)
            }
        }
    }

    private func repairCoverWithAlternateCovers(
        for entry: LegacyHistoryEntry,
        source: AidokuRunnerLegacySource,
        oldCoverURL: URL?
    ) {
        guard source.runner.features.providesAlternateCovers else { return }
        source.runner.getAlternateCovers(manga: entry.manga) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard case .success(let covers) = result else { return }
                let cover = covers
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                guard let cover = cover else { return }
                var manga = entry.manga
                manga.cover = cover
                guard !manga.coverURLCandidates(relativeTo: source.urls.first).isEmpty else { return }
                if let oldCoverURL = oldCoverURL {
                    LegacyImageLoader.shared.removeCachedImage(for: oldCoverURL, source: source)
                }
                LegacyImageLoader.shared.removeCachedImages(for: manga.coverURLCandidates(relativeTo: source.urls.first), source: source)
                LegacyLibraryStore.shared.updateMangaMetadata(manga: manga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: manga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: manga, source: source)
                self.reloadVisibleHistoryEntry(with: entry.key)
            }
        }
    }

    private func reloadVisibleHistoryEntry(with key: String) {
        guard let indexPath = indexPath(forKey: key) else { return }
        guard let refreshedEntry = LegacyHistoryStore.shared.entries.first(where: { $0.key == key }) else {
            reloadData()
            return
        }
        sectionsData[indexPath.section].entries[indexPath.row] = refreshedEntry
        guard tableView.indexPathsForVisibleRows?.contains(indexPath) == true else { return }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyUpdatesViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var entries: [LegacyUpdateEntry] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?
    private var pendingCoverRepairs = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Updates"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = 86
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(confirmClear))
        observer = NotificationCenter.default.addObserver(
            forName: .legacyUpdatesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadData() {
        entries = LegacyUpdateStore.shared.entries
        sources = packageInstaller.loadInstalledSources()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.isEmpty ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UpdateCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "UpdateCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        guard !entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "No new chapters recorded."
            cell.detailTextLabel?.text = "Use Library Update to check saved manga."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        let entry = entries[indexPath.row]
        loadCover(for: entry, into: cell, at: indexPath)
        cell.textLabel?.text = entry.manga.title
        let dateText = DateFormatter.localizedString(from: entry.dateFound, dateStyle: .short, timeStyle: .short)
        cell.detailTextLabel?.text = "\(entry.chapter.legacyFormattedTitle)\n\(entry.sourceName) - \(dateText)"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to open this manga.")
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entry.manga),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        LegacyUpdateStore.shared.remove(key: entries[indexPath.row].key)
    }

    private func loadCover(for entry: LegacyUpdateEntry, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else { return }
        let coverURLs = entry.manga.coverURLCandidates(relativeTo: source.urls.first)
        guard !coverURLs.isEmpty else {
            repairCover(for: entry, source: source)
            return
        }
        LegacyImageLoader.shared.loadCover(
            urls: coverURLs,
            source: source,
            targetHeight: 130
        ) { [weak self] image in
            guard
                let self = self,
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
            if image == nil {
                self.repairCover(for: entry, source: source)
            }
        }
    }

    private func repairCover(for entry: LegacyUpdateEntry, source: AidokuRunnerLegacySource) {
        guard !pendingCoverRepairs.contains(entry.key) else { return }
        pendingCoverRepairs.insert(entry.key)
        source.runner.getMangaUpdate(manga: entry.manga, needsDetails: true, needsChapters: false) { [weak self] result in
            DispatchQueue.main.async {
                self?.pendingCoverRepairs.remove(entry.key)
                guard case .success(let updatedManga) = result else { return }
                let mergedManga = entry.manga.mergedWithUpdate(updatedManga)
                guard mergedManga.coverURL(relativeTo: source.urls.first) != nil else { return }
                LegacyLibraryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyHistoryStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
                LegacyUpdateStore.shared.updateMangaMetadata(manga: mergedManga, source: source)
            }
        }
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(title: "Clear Updates", message: "Remove recorded chapter updates?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyUpdateStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyDownloadsViewController: UITableViewController {
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var entries: [LegacyDownloadedChapter] = []
    private var sources: [AidokuRunnerLegacySource] = []
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = 86
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(confirmClear))
        observer = NotificationCenter.default.addObserver(
            forName: .legacyDownloadsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
        reloadData()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadData() {
        entries = LegacyDownloadStore.shared.downloadedChapters
        sources = packageInstaller.loadInstalledSources()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.isEmpty ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "DownloadCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        guard !entries.isEmpty else {
            cell.textLabel?.text = "No downloaded chapters."
            cell.detailTextLabel?.text = "Open a manga and download chapters for offline reading."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        let entry = entries[indexPath.row]
        cell.textLabel?.text = entry.manga.title
        let size = ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
        cell.detailTextLabel?.text = "\(entry.chapter.legacyFormattedTitle)\n\(entry.sourceName) - \(entry.pageCount) pages - \(size)"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        guard let source = sources.first(where: { $0.key == entry.sourceKey }) else {
            showAlert(title: "Source Missing", message: "Install \(entry.sourceName) again to read this download.")
            return
        }
        navigationController?.pushViewController(
            LegacyReaderFactory.makeReader(source: source, manga: entry.manga, chapter: entry.chapter),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        LegacyDownloadStore.shared.delete(entries[indexPath.row])
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(title: "Clear Downloads", message: "Remove all downloaded chapters?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            LegacyDownloadStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyDownloadSettingsViewController: UITableViewController {
    private enum Row {
        case deleteAfterReading
        case downloadNextUnread
        case downloads
        case clearDownloads
    }

    private struct Section {
        let title: String
        let footer: String?
        let rows: [Row]
    }

    private let sections: [Section] = [
        Section(
            title: "Automation",
            footer: "Automation runs only when the reader reaches the end of a chapter. Incognito reading skips these actions.",
            rows: [.deleteAfterReading, .downloadNextUnread]
        ),
        Section(
            title: "Manage",
            footer: nil,
            rows: [.downloads, .clearDownloads]
        )
    ]

    init() {
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private func row(at indexPath: IndexPath) -> Row {
        return sections[indexPath.section].rows[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadSettingsCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "DownloadSettingsCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .default
        cell.accessoryType = .none

        switch row(at: indexPath) {
            case .deleteAfterReading:
                let enabled = aidokuLegacyDownloadsDeleteAfterReading()
                cell.textLabel?.text = "Delete After Reading"
                cell.detailTextLabel?.text = enabled
                    ? "Downloaded chapters are removed after completion."
                    : "Keep downloads after completion."
                cell.accessoryType = enabled ? .checkmark : .none
            case .downloadNextUnread:
                let enabled = aidokuLegacyDownloadsDownloadNextUnreadAfterReading()
                cell.textLabel?.text = "Download Next Unread"
                cell.detailTextLabel?.text = enabled
                    ? "Queue the next unread chapter after completion."
                    : "Do not queue chapters automatically."
                cell.accessoryType = enabled ? .checkmark : .none
            case .downloads:
                let count = LegacyDownloadStore.shared.downloadedChapters.count
                cell.textLabel?.text = "Downloaded Chapters"
                cell.detailTextLabel?.text = count == 1 ? "1 downloaded chapter" : "\(count) downloaded chapters"
                cell.accessoryType = .disclosureIndicator
            case .clearDownloads:
                cell.textLabel?.text = "Clear Downloads"
                cell.textLabel?.textColor = UIColor.red
                cell.detailTextLabel?.text = "Remove all downloaded chapters."
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch row(at: indexPath) {
            case .deleteAfterReading:
                aidokuLegacySetDownloadsDeleteAfterReading(!aidokuLegacyDownloadsDeleteAfterReading())
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .downloadNextUnread:
                aidokuLegacySetDownloadsDownloadNextUnreadAfterReading(!aidokuLegacyDownloadsDownloadNextUnreadAfterReading())
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .downloads:
                navigationController?.pushViewController(LegacyDownloadsViewController(), animated: true)
            case .clearDownloads:
                confirmClearDownloads()
        }
    }

    private func confirmClearDownloads() {
        let alert = UIAlertController(title: "Clear Downloads", message: "Remove all downloaded chapters?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            LegacyDownloadStore.shared.clear()
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}

final class LegacyCategoryManagerViewController: UITableViewController {
    private enum SectionKind: Equatable {
        case categories
        case add
        case defaultCategory
    }

    private let sectionOrder: [SectionKind] = [.categories, .add, .defaultCategory]
    private var categories: [String] = []

    init() {
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library Categories"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        navigationItem.rightBarButtonItem = editButtonItem
        reloadCategories()
    }

    private func reloadCategories() {
        categories = LegacyCategoryStore.shared.categories
        tableView.reloadData()
    }

    private func kind(for section: Int) -> SectionKind {
        sectionOrder[section]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sectionOrder.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch kind(for: section) {
            case .categories:
                return max(categories.count, 1)
            case .add:
                return 1
            case .defaultCategory:
                return categories.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch kind(for: section) {
            case .categories:
                return "Categories"
            case .add:
                return nil
            case .defaultCategory:
                return "Default Category"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch kind(for: section) {
            case .categories:
                return "Tap a category to rename it, set its own sort order, make it the default, or remove it."
            case .defaultCategory:
                return "New manga added to the Library are filed under the default category."
            case .add:
                return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CategoryCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "CategoryCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryType = .none
        cell.selectionStyle = .default

        switch kind(for: indexPath.section) {
            case .categories:
                if categories.isEmpty {
                    cell.textLabel?.text = "No categories yet"
                    cell.detailTextLabel?.text = "Add a category to organize your library."
                    cell.selectionStyle = .none
                } else {
                    let name = categories[indexPath.row]
                    cell.textLabel?.text = name
                    let sort = LegacyCategoryStore.shared.sort(forKey: name)
                    let isDefault = LegacyCategoryStore.shared.defaultCategory.caseInsensitiveCompare(name) == .orderedSame
                    var detail = "Sort: \(sort.title)"
                    if isDefault { detail += " - Default" }
                    cell.detailTextLabel?.text = detail
                    cell.accessoryType = .disclosureIndicator
                }
            case .add:
                cell.textLabel?.text = "Add Category"
                cell.textLabel?.textColor = LegacyPalette.accent
                cell.detailTextLabel?.text = nil
            case .defaultCategory:
                let isNone = indexPath.row == 0
                let name = isNone ? "" : categories[indexPath.row - 1]
                cell.textLabel?.text = isNone ? "None" : name
                cell.detailTextLabel?.text = nil
                let current = LegacyCategoryStore.shared.defaultCategory
                let selected = isNone ? current.isEmpty : current.caseInsensitiveCompare(name) == .orderedSame
                cell.accessoryType = selected ? .checkmark : .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch kind(for: indexPath.section) {
            case .categories:
                guard !categories.isEmpty else { return }
                showCategoryOptions(for: categories[indexPath.row], at: indexPath)
            case .add:
                promptAddCategory()
            case .defaultCategory:
                let value = indexPath.row == 0 ? "" : categories[indexPath.row - 1]
                LegacyCategoryStore.shared.defaultCategory = value
                if let section = sectionOrder.firstIndex(of: .defaultCategory) {
                    tableView.reloadSections(IndexSet(integer: section), with: .automatic)
                }
        }
    }

    // MARK: Editing

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        kind(for: indexPath.section) == .categories && !categories.isEmpty
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        kind(for: indexPath.section) == .categories && !categories.isEmpty
    }

    override func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        canEditRow(indexPath) ? .delete : .none
    }

    private func canEditRow(_ indexPath: IndexPath) -> Bool {
        kind(for: indexPath.section) == .categories && !categories.isEmpty
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, kind(for: indexPath.section) == .categories,
              categories.indices.contains(indexPath.row) else { return }
        LegacyCategoryStore.shared.remove(categories[indexPath.row])
        reloadCategories()
    }

    override func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        // Keep reordering within the categories section.
        if kind(for: proposedDestinationIndexPath.section) != .categories {
            let lastRow = max(categories.count - 1, 0)
            return IndexPath(row: lastRow, section: sourceIndexPath.section)
        }
        return proposedDestinationIndexPath
    }

    override func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        LegacyCategoryStore.shared.move(from: sourceIndexPath.row, to: destinationIndexPath.row)
        categories = LegacyCategoryStore.shared.categories
    }

    // MARK: Actions

    private func promptAddCategory() {
        let alert = UIAlertController(title: "Add Category", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Reading"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !LegacyCategoryStore.shared.add(name) {
                self?.showAlert(title: "Category Exists", message: "A category with that name already exists.")
            }
            self?.reloadCategories()
        })
        present(alert, animated: true)
    }

    private func showCategoryOptions(for name: String, at indexPath: IndexPath) {
        let alert = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            self?.promptRenameCategory(name)
        })
        let sort = LegacyCategoryStore.shared.sort(forKey: name)
        alert.addAction(UIAlertAction(title: "Sort: \(sort.title)", style: .default) { [weak self] _ in
            self?.showSortOptions(for: name, at: indexPath)
        })
        let isDefault = LegacyCategoryStore.shared.defaultCategory.caseInsensitiveCompare(name) == .orderedSame
        alert.addAction(UIAlertAction(title: isDefault ? "Remove as Default" : "Make Default", style: .default) { [weak self] _ in
            LegacyCategoryStore.shared.defaultCategory = isDefault ? "" : name
            self?.reloadCategories()
        })
        alert.addAction(UIAlertAction(title: "Remove Category", style: .destructive) { [weak self] _ in
            LegacyCategoryStore.shared.remove(name)
            self?.reloadCategories()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func showSortOptions(for name: String, at indexPath: IndexPath) {
        let current = LegacyCategoryStore.shared.sort(forKey: name)
        let alert = UIAlertController(title: "Sort - \(name)", message: nil, preferredStyle: .actionSheet)
        for option in LegacyLibrarySortOption.allCases {
            let title = option == current ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                LegacyCategoryStore.shared.setSort(option, forKey: name)
                self?.reloadCategories()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func promptRenameCategory(_ name: String) {
        let alert = UIAlertController(title: "Rename Category", message: name, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = name
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let newName = alert?.textFields?.first?.text ?? ""
            guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            LegacyCategoryStore.shared.rename(name, to: newName)
            self?.reloadCategories()
        })
        present(alert, animated: true)
    }

    private func presentSheet(_ alert: UIAlertController, at indexPath: IndexPath) {
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacySettingsViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Row: Int, CaseIterable {
        case readerMode
        case readerMemory
        case readerUpscale
        case readerPageNumber
        case readerTapZones
        case readerColors
        case darkTheme
        case incognitoMode
        case privacyShield
        case clearCookies
        case clearWebViewData
        case dnsOverHttps
        case defaultUserAgent
        case automaticLibraryUpdates
        case automaticSourceUpdates
        case updateNotifications
        case readingInsights
        case manageCategories
        case downloads
        case localFiles
        case selfHosted
        case trackers
        case createBackup
        case restoreBackup
        case importModernBackup
        case exportModernBackup
        case automaticModernBackups
        case clearImageCache
        case clearHistory
        case clearLibrary
        case about
    }

    private struct Section {
        let titleKey: String
        let rows: [Row]
    }

    private let sections: [Section] = [
        Section(titleKey: "settings.section.reader", rows: [.readerMode, .readerColors, .readerMemory, .readerUpscale, .readerPageNumber, .readerTapZones]),
        Section(titleKey: "settings.section.appearance", rows: [.darkTheme]),
        Section(titleKey: "settings.section.privacy", rows: [.incognitoMode, .privacyShield]),
        Section(titleKey: "settings.section.networking", rows: [.clearCookies, .clearWebViewData, .dnsOverHttps, .defaultUserAgent]),
        Section(titleKey: "settings.section.updates", rows: [.automaticLibraryUpdates, .automaticSourceUpdates, .updateNotifications]),
        Section(titleKey: "settings.section.library", rows: [.readingInsights, .manageCategories, .downloads, .localFiles, .selfHosted, .trackers]),
        Section(
            titleKey: "settings.section.backup_restore",
            rows: [.createBackup, .restoreBackup, .importModernBackup, .exportModernBackup, .automaticModernBackups]
        ),
        Section(titleKey: "settings.section.storage", rows: [.clearImageCache, .clearHistory, .clearLibrary]),
        Section(titleKey: "settings.section.about", rows: [.about])
    ]

    private func row(at indexPath: IndexPath) -> Row {
        return sections[indexPath.section].rows[indexPath.row]
    }

    private var importsModernBackup = false

    init() {
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = LegacyString("settings.title")
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return LegacyString(sections[section].titleKey)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = self.row(at: indexPath)
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SettingsCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryType = row == .about ? .none : .disclosureIndicator
        cell.selectionStyle = row == .about ? .none : .default

        switch row {
            case .readerMode:
                let mode = LegacyReaderMode.current
                cell.textLabel?.text = LegacyString("settings.reader_layout")
                cell.detailTextLabel?.text = String(format: LegacyString("settings.reader_layout.detail"), mode.title, mode.detail)
            case .readerColors:
                cell.textLabel?.text = LegacyString("settings.reader_colors")
                cell.detailTextLabel?.text = LegacyString("settings.reader_colors.detail")
            case .readerMemory:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.downsampleImages")
                cell.textLabel?.text = LegacyString("settings.reader_memory_mode")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.reader_memory_mode.on")
                    : LegacyString("settings.reader_memory_mode.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .readerUpscale:
                let enabled = aidokuLegacyReaderUpscaleImages()
                let detail: String
                if enabled {
                    detail = LegacyString("settings.reader_upscale.on")
                } else {
                    detail = LegacyString("settings.reader_upscale.off")
                }
                cell.textLabel?.text = LegacyString("settings.reader_upscale")
                cell.detailTextLabel?.text = detail
                cell.accessoryType = enabled ? .checkmark : .none
            case .readerPageNumber:
                let enabled = aidokuLegacyReaderShowsPageNumber()
                cell.textLabel?.text = LegacyString("settings.reader_page_number")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.reader_page_number.on")
                    : LegacyString("settings.reader_page_number.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .readerTapZones:
                let enabled = aidokuLegacyReaderShowsTapZones()
                cell.textLabel?.text = LegacyString("settings.tap_zones_overlay")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.tap_zones_overlay.on")
                    : LegacyString("settings.tap_zones_overlay.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .darkTheme:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.appearance.darkTheme")
                cell.textLabel?.text = LegacyString("settings.dark_theme")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.dark_theme.on")
                    : LegacyString("settings.dark_theme.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .incognitoMode:
                let enabled = aidokuLegacyIncognitoEnabled()
                cell.textLabel?.text = LegacyString("settings.incognito_mode")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.incognito_mode.on")
                    : LegacyString("settings.incognito_mode.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .privacyShield:
                let enabled = aidokuLegacyPrivacyShieldEnabled()
                cell.textLabel?.text = LegacyString("settings.privacy_shield")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.privacy_shield.on")
                    : LegacyString("settings.privacy_shield.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .clearCookies:
                cell.textLabel?.text = LegacyString("settings.clear_cookies")
                cell.detailTextLabel?.text = LegacyString("settings.clear_cookies.detail")
                cell.accessoryType = .none
            case .clearWebViewData:
                cell.textLabel?.text = LegacyString("settings.clear_web_view_data")
                cell.detailTextLabel?.text = LegacyString("settings.clear_web_view_data.detail")
                cell.accessoryType = .none
            case .dnsOverHttps:
                cell.textLabel?.text = LegacyString("settings.dns_over_https")
                cell.detailTextLabel?.text = LegacyNetworkSettings.dohEnabled
                    ? String(format: LegacyString("settings.dns_over_https.on"), LegacyNetworkSettings.dohProviderDisplayName)
                    : LegacyString("settings.dns_over_https.off")
            case .defaultUserAgent:
                cell.textLabel?.text = LegacyString("settings.default_user_agent")
                cell.detailTextLabel?.text = LegacyNetworkSettings.defaultUserAgent
            case .automaticLibraryUpdates:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.library.automaticUpdates")
                cell.textLabel?.text = LegacyString("settings.auto_library_updates")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.auto_library_updates.on")
                    : LegacyString("settings.auto_library_updates.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .automaticSourceUpdates:
                let enabled = UserDefaults.standard.bool(forKey: "AidokuLegacy.sources.automaticUpdates")
                cell.textLabel?.text = LegacyString("settings.auto_source_updates")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.auto_source_updates.on")
                    : LegacyString("settings.auto_source_updates.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .updateNotifications:
                let enabled = LegacyUpdateNotificationManager.shared.isEnabled
                cell.textLabel?.text = LegacyString("settings.update_notifications")
                cell.detailTextLabel?.text = enabled
                    ? LegacyString("settings.update_notifications.on")
                    : LegacyString("settings.update_notifications.off")
                cell.accessoryType = enabled ? .checkmark : .none
            case .readingInsights:
                let total = LegacyReadingStatsStore.shared.totalChapters
                cell.textLabel?.text = LegacyString("settings.reading_insights")
                cell.detailTextLabel?.text = total == 0
                    ? LegacyString("settings.reading_insights.zero")
                    : (total == 1
                        ? LegacyString("settings.reading_insights.one")
                        : String(format: LegacyString("settings.reading_insights.many"), total))
            case .manageCategories:
                let count = LegacyCategoryStore.shared.categories.count
                cell.textLabel?.text = LegacyString("settings.library_categories")
                let defaultCategory = LegacyCategoryStore.shared.defaultCategory
                if count == 0 {
                    cell.detailTextLabel?.text = LegacyString("settings.library_categories.zero")
                } else {
                    let base = count == 1
                        ? LegacyString("settings.library_categories.one")
                        : String(format: LegacyString("settings.library_categories.many"), count)
                    cell.detailTextLabel?.text = defaultCategory.isEmpty
                        ? base
                        : String(format: LegacyString("settings.library_categories.default"), base, defaultCategory)
                }
            case .downloads:
                let count = LegacyDownloadStore.shared.downloadedChapters.count
                cell.textLabel?.text = LegacyString("settings.downloads")
                var details = [
                    count == 1
                        ? LegacyString("settings.downloads.one")
                        : String(format: LegacyString("settings.downloads.many"), count)
                ]
                if aidokuLegacyDownloadsDeleteAfterReading() {
                    details.append(LegacyString("settings.downloads.delete_after_reading"))
                }
                if aidokuLegacyDownloadsDownloadNextUnreadAfterReading() {
                    details.append(LegacyString("settings.downloads.download_next_unread"))
                }
                cell.detailTextLabel?.text = details.joined(separator: LegacyString("settings.detail_separator"))
            case .localFiles:
                let count = LegacyLocalFileStore.shared.mangaList.count
                cell.textLabel?.text = LegacyString("settings.local_files")
                cell.detailTextLabel?.text = count == 0
                    ? LegacyString("settings.local_files.zero")
                    : (count == 1
                        ? LegacyString("settings.local_files.one")
                        : String(format: LegacyString("settings.local_files.many"), count))
            case .selfHosted:
                let count = LegacyKomgaServerStore.shared.servers.count
                cell.textLabel?.text = LegacyString("settings.self_hosted")
                cell.detailTextLabel?.text = count == 0
                    ? LegacyString("settings.self_hosted.zero")
                    : (count == 1
                        ? LegacyString("settings.self_hosted.one")
                        : String(format: LegacyString("settings.self_hosted.many"), count))
            case .trackers:
                cell.textLabel?.text = LegacyString("settings.trackers")
                let connected = LegacyTrackerManager.shared.loggedInTrackers
                if connected.isEmpty {
                    cell.detailTextLabel?.text = LegacyString("settings.trackers.empty")
                } else {
                    cell.detailTextLabel?.text = String(
                        format: LegacyString("settings.trackers.connected"),
                        connected.map { $0.displayName }.joined(separator: ", ")
                    )
                }
            case .createBackup:
                cell.textLabel?.text = LegacyString("settings.create_backup")
                cell.detailTextLabel?.text = LegacyString("settings.create_backup.detail")
            case .restoreBackup:
                cell.textLabel?.text = LegacyString("settings.restore_backup")
                cell.detailTextLabel?.text = LegacyString("settings.restore_backup.detail")
            case .importModernBackup:
                cell.textLabel?.text = LegacyString("settings.import_modern_backup")
                cell.detailTextLabel?.text = LegacyString("settings.import_modern_backup.detail")
            case .exportModernBackup:
                cell.textLabel?.text = LegacyString("settings.export_modern_backup")
                cell.detailTextLabel?.text = LegacyString("settings.export_modern_backup.detail")
            case .automaticModernBackups:
                let scheduler = LegacyModernAutomaticBackupScheduler.shared
                cell.textLabel?.text = LegacyString("settings.automatic_modern_backups")
                if scheduler.isEnabled {
                    if let lastBackupDate = scheduler.lastBackupDate {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        formatter.timeStyle = .short
                        cell.detailTextLabel?.text = String(
                            format: LegacyString("settings.automatic_modern_backups.last"),
                            formatter.string(from: lastBackupDate)
                        )
                    } else {
                        cell.detailTextLabel?.text = LegacyString("settings.automatic_modern_backups.pending")
                    }
                } else {
                    cell.detailTextLabel?.text = LegacyString("settings.automatic_modern_backups.off")
                }
                cell.accessoryType = scheduler.isEnabled ? .checkmark : .none
            case .clearImageCache:
                cell.textLabel?.text = LegacyString("settings.clear_image_cache")
                cell.detailTextLabel?.text = LegacyString("settings.clear_image_cache.detail")
            case .clearHistory:
                cell.textLabel?.text = LegacyString("settings.clear_history")
                cell.detailTextLabel?.text = LegacyString("settings.clear_history.detail")
            case .clearLibrary:
                cell.textLabel?.text = LegacyString("settings.clear_library")
                cell.detailTextLabel?.text = LegacyString("settings.clear_library.detail")
            case .about:
                cell.textLabel?.text = LegacyString("settings.about.title")
                cell.detailTextLabel?.text = LegacyString("settings.about.detail")
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = self.row(at: indexPath)
        switch row {
            case .readerMode:
                showReaderModePicker(from: indexPath)
            case .readerColors:
                navigationController?.pushViewController(LegacyReaderSettingsViewController(), animated: true)
            case .readerMemory:
                let key = "AidokuLegacy.reader.downsampleImages"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                aidokuLegacyTrimVolatileCaches()
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .readerUpscale:
                let key = "AidokuLegacy.reader.upscaleImages"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                aidokuLegacyTrimVolatileCaches()
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .readerPageNumber:
                let key = "AidokuLegacy.reader.showPageNumber"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .readerTapZones:
                let key = "AidokuLegacy.reader.showTapZones"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .darkTheme:
                let key = "AidokuLegacy.appearance.darkTheme"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                view.backgroundColor = LegacyPalette.background
                tableView.backgroundColor = LegacyPalette.background
                tableView.reloadData()
                NotificationCenter.default.post(name: .legacyAppearanceDidChange, object: nil)
            case .incognitoMode:
                let key = "AidokuLegacy.reader.incognito"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .privacyShield:
                aidokuLegacySetPrivacyShieldEnabled(!aidokuLegacyPrivacyShieldEnabled())
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .clearCookies:
                confirmClearCookies(at: indexPath)
            case .clearWebViewData:
                confirmClearWebViewData(at: indexPath)
            case .dnsOverHttps:
                showDoHOptions(from: indexPath)
            case .defaultUserAgent:
                showUserAgentEditor(at: indexPath)
            case .automaticLibraryUpdates:
                let key = "AidokuLegacy.library.automaticUpdates"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .automaticSourceUpdates:
                let key = "AidokuLegacy.sources.automaticUpdates"
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .updateNotifications:
                toggleUpdateNotifications(at: indexPath)
            case .readingInsights:
                navigationController?.pushViewController(LegacyInsightsViewController(), animated: true)
            case .manageCategories:
                navigationController?.pushViewController(LegacyCategoryManagerViewController(), animated: true)
            case .downloads:
                navigationController?.pushViewController(LegacyDownloadSettingsViewController(), animated: true)
            case .localFiles:
                openLocalFiles()
            case .selfHosted:
                openSelfHosted()
            case .trackers:
                showTrackerOptions(from: indexPath)
            case .createBackup:
                createBackup()
            case .restoreBackup:
                showRestoreOptions(from: indexPath)
            case .importModernBackup:
                openModernBackupPicker()
            case .exportModernBackup:
                exportModernBackup()
            case .automaticModernBackups:
                let scheduler = LegacyModernAutomaticBackupScheduler.shared
                scheduler.isEnabled = !scheduler.isEnabled
                tableView.reloadRows(at: [indexPath], with: .automatic)
            case .clearImageCache:
                LegacyImageLoader.shared.clear()
            case .clearHistory:
                confirmClearHistory()
            case .clearLibrary:
                confirmClearLibrary()
            case .about:
                break
        }
    }

    private func createBackup() {
        do {
            let url = try LegacyBackupManager.shared.createBackup()
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            present(controller, animated: true)
        } catch {
            showAlert(title: LegacyString("backup.failed.title"), message: error.localizedDescription)
        }
    }

    private func showRestoreOptions(from indexPath: IndexPath) {
        let backups = LegacyBackupManager.shared.backupURLs()
        let alert = UIAlertController(title: LegacyString("backup.restore.title"), message: nil, preferredStyle: .actionSheet)
        if let latest = backups.first {
            alert.addAction(UIAlertAction(title: LegacyString("backup.restore_latest"), style: .default) { [weak self] _ in
                self?.confirmRestore(url: latest)
            })
        }
        alert.addAction(UIAlertAction(title: LegacyString("backup.import_file"), style: .default) { [weak self] _ in
            self?.openBackupPicker()
        })
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func openBackupPicker() {
        importsModernBackup = false
        let picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.data"], in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    private func openModernBackupPicker() {
        importsModernBackup = true
        let picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.data"], in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    private func importModernBackup(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        LegacyModernBackupImporter.shared.importBackup(at: url) { [weak self] result in
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            guard let self = self else { return }
            switch result {
                case .success(let summary):
                    self.tableView.reloadData()
                    self.showAlert(
                        title: LegacyString("backup.imported.title"),
                        message: String(
                            format: LegacyString("backup.imported.message"),
                            summary.libraryAdded,
                            summary.historyAdded,
                            summary.updatesAdded
                        )
                    )
                case .failure(let error):
                    self.showAlert(title: LegacyString("backup.import_failed.title"), message: error.localizedDescription)
            }
        }
    }

    private func exportModernBackup() {
        LegacyModernBackupExporter.shared.exportBackup { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let url):
                    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let popover = controller.popoverPresentationController {
                        popover.sourceView = self.view
                        popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    }
                    self.present(controller, animated: true)
                case .failure(let error):
                    self.showAlert(title: LegacyString("backup.export_failed.title"), message: error.localizedDescription)
            }
        }
    }

    private func openLocalFiles() {
        let localFilesVC = LegacyLocalFilesViewController()
        localFilesVC.onOpenChapter = { [weak self] manga, chapter in
            self?.presentLocalReader(manga: manga, chapter: chapter)
        }
        navigationController?.pushViewController(localFilesVC, animated: true)
    }

    private func presentLocalReader(manga localManga: LegacyLocalManga, chapter localChapter: LegacyLocalChapter) {
        let runner = LegacyLocalFileRunner(localManga: localManga, localChapter: localChapter)
        let info = AidokuRunnerLegacySourceInfo(
            info: .init(
                id: "local",
                name: "Local Files",
                altNames: nil,
                version: 1,
                url: nil,
                urls: nil,
                contentRating: .safe,
                languages: ["en"],
                minAppVersion: nil,
                maxAppVersion: nil
            ),
            listings: nil,
            config: nil
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AidokuLegacyLocalSource-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = AidokuRunnerLegacySource(url: directory, info: info, runner: runner)
        let manga = AidokuRunnerLegacyManga(
            sourceKey: "local",
            key: localManga.id,
            title: localManga.title,
            cover: nil,
            artists: nil,
            authors: nil,
            description: localManga.description,
            url: nil,
            tags: nil,
            chapters: nil
        )
        let chapter = AidokuRunnerLegacyChapter(
            key: localChapter.id,
            title: localChapter.title,
            chapterNumber: localChapter.chapterNumber,
            volumeNumber: localChapter.volumeNumber
        )
        let reader = LegacyReaderFactory.makeReader(source: source, manga: manga, chapter: chapter)
        navigationController?.pushViewController(reader, animated: true)
    }

    private func openSelfHosted() {
        let serversVC = LegacyKomgaServerListViewController()
        serversVC.onSelectServer = { [weak self] server in
            let browseVC = LegacyKomgaSeriesListViewController(server: server)
            self?.navigationController?.pushViewController(browseVC, animated: true)
        }
        navigationController?.pushViewController(serversVC, animated: true)
    }

    private func toggleUpdateNotifications(at indexPath: IndexPath) {
        let manager = LegacyUpdateNotificationManager.shared
        if manager.isEnabled {
            manager.isEnabled = false
            tableView.reloadRows(at: [indexPath], with: .automatic)
        } else {
            manager.requestAuthorization { [weak self] granted in
                if !granted {
                    self?.showAlert(
                        title: LegacyString("settings.notifications_disabled.title"),
                        message: LegacyString("settings.notifications_disabled.message")
                    )
                }
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            }
        }
    }

    private func showTrackerOptions(from indexPath: IndexPath) {
        let manager = LegacyTrackerManager.shared
        let alert = UIAlertController(title: "Trackers", message: nil, preferredStyle: .actionSheet)
        for trackerId in LegacyTrackerId.allCases {
            if manager.isLoggedIn(trackerId) {
                alert.addAction(UIAlertAction(title: "Log Out of \(trackerId.displayName)", style: .destructive) { [weak self] _ in
                    manager.logout(trackerId)
                    self?.tableView.reloadData()
                })
            } else {
                alert.addAction(UIAlertAction(title: "Connect \(trackerId.displayName)", style: .default) { [weak self] _ in
                    self?.presentTrackerLogin(trackerId)
                })
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func presentTrackerLogin(_ trackerId: LegacyTrackerId) {
        let isConfigured: Bool
        switch trackerId {
            case .anilist:
                isConfigured = LegacyAniListTracker.shared.isClientConfigured
            case .myanimelist:
                isConfigured = LegacyMyAnimeListTracker.shared.isClientConfigured
        }
        guard isConfigured else {
            promptForClientId(trackerId)
            return
        }
        let loginVC = LegacyTrackerLoginViewController(trackerId: trackerId) { [weak self] _ in
            self?.tableView.reloadData()
        }
        let nav = UINavigationController(rootViewController: loginVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func promptForClientId(_ trackerId: LegacyTrackerId) {
        let title: String
        let message: String
        let currentValue: String
        switch trackerId {
            case .anilist:
                title = "AniList Client ID"
                message = "Create an API client at anilist.co (Settings -> Developer) with redirect URL "
                    + "https://anilist.co/api/v2/oauth/pin, then paste its Client ID here."
                currentValue = LegacyAniListTracker.shared.isClientConfigured ? LegacyAniListTracker.shared.clientId : ""
            case .myanimelist:
                title = "MyAnimeList Client ID"
                message = "Create an API app at myanimelist.net (Account Settings -> API) and paste its Client ID here."
                currentValue = LegacyMyAnimeListTracker.shared.isClientConfigured ? LegacyMyAnimeListTracker.shared.clientId : ""
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Client ID"
            if trackerId == .anilist {
                textField.keyboardType = .numberPad
            }
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.text = currentValue
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save & Connect", style: .default) { [weak self, weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch trackerId {
                case .anilist:
                    LegacyAniListTracker.shared.setClientId(trimmed)
                case .myanimelist:
                    LegacyMyAnimeListTracker.shared.setClientId(trimmed)
            }
            self?.presentTrackerLogin(trackerId)
        })
        present(alert, animated: true)
    }

    private func confirmRestore(url: URL) {
        let alert = UIAlertController(
            title: LegacyString("backup.restore.title"),
            message: LegacyString("backup.restore.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("button.restore"), style: .destructive) { [weak self] _ in
            self?.restoreBackup(url: url)
        })
        present(alert, animated: true)
    }

    private func restoreBackup(url: URL) {
        do {
            try LegacyBackupManager.shared.restore(from: url)
            tableView.reloadData()
            showAlert(title: LegacyString("backup.restored.title"), message: LegacyString("backup.restored.message"))
        } catch {
            showAlert(title: LegacyString("backup.restore_failed.title"), message: error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if importsModernBackup {
            importsModernBackup = false
            importModernBackup(url: url)
        } else {
            confirmRestore(url: url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        dismiss(animated: true)
    }

    private func showReaderModePicker(from indexPath: IndexPath) {
        let currentMode = LegacyReaderMode.current
        let alert = UIAlertController(
            title: LegacyString("settings.reader_layout"),
            message: LegacyString("settings.reader_layout.message"),
            preferredStyle: .actionSheet
        )
        for mode in LegacyReaderMode.allCases {
            let title = mode == currentMode
                ? String(format: LegacyString("settings.option.current"), mode.title)
                : mode.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                LegacyReaderMode.setCurrent(mode)
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            })
        }
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func confirmClearCookies(at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: LegacyString("settings.clear_cookies"),
            message: LegacyString("settings.clear_cookies.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("button.clear"), style: .destructive) { [weak self] _ in
            self?.clearCookies(at: indexPath)
        })
        present(alert, animated: true)
    }

    private func clearCookies(at indexPath: IndexPath) {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] {
            storage.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: [WKWebsiteDataTypeCookies]) { records in
            store.removeData(ofTypes: [WKWebsiteDataTypeCookies], for: records) { [weak self] in
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
                self?.showAlert(title: LegacyString("settings.cookies_cleared.title"), message: LegacyString("settings.cookies_cleared.message"))
            }
        }
    }

    private func confirmClearWebViewData(at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: LegacyString("settings.clear_web_view_data"),
            message: LegacyString("settings.clear_web_view_data.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("button.clear"), style: .destructive) { [weak self] _ in
            self?.clearWebViewData()
        })
        present(alert, animated: true)
    }

    private func clearWebViewData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(
            ofTypes: types,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            self?.showAlert(
                title: LegacyString("settings.web_view_data_cleared.title"),
                message: LegacyString("settings.web_view_data_cleared.message")
            )
        }
    }

    private func showDoHOptions(from indexPath: IndexPath) {
        let alert = UIAlertController(
            title: LegacyString("settings.dns_over_https"),
            message: LegacyString("settings.dns_over_https.message"),
            preferredStyle: .actionSheet
        )

        func providerActionTitle(_ provider: String, _ display: String) -> String {
            let isActive = LegacyNetworkSettings.dohEnabled && LegacyNetworkSettings.dohProvider == provider
            return isActive ? "\u{2713} \(display)" : display
        }

        alert.addAction(UIAlertAction(title: providerActionTitle("cloudflare", "Cloudflare"), style: .default) { [weak self] _ in
            self?.setDoH(enabled: true, provider: "cloudflare", at: indexPath)
        })
        alert.addAction(UIAlertAction(title: providerActionTitle("google", "Google"), style: .default) { [weak self] _ in
            self?.setDoH(enabled: true, provider: "google", at: indexPath)
        })
        alert.addAction(UIAlertAction(title: providerActionTitle("custom", LegacyString("settings.dns_over_https.custom_url")), style: .default) { [weak self] _ in
            self?.promptCustomDoHURL(at: indexPath)
        })
        if LegacyNetworkSettings.dohEnabled {
            alert.addAction(UIAlertAction(title: LegacyString("settings.turn_off"), style: .destructive) { [weak self] _ in
                self?.setDoH(enabled: false, provider: LegacyNetworkSettings.dohProvider, at: indexPath)
            })
        }
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        presentSheet(alert, from: indexPath)
    }

    private func promptCustomDoHURL(at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: LegacyString("settings.custom_doh.title"),
            message: LegacyString("settings.custom_doh.message"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "https://dns.example/dns-query"
            field.text = LegacyNetworkSettings.dohCustomURL
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("button.save"), style: .default) { [weak self] _ in
            let value = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let url = URL(string: value), url.scheme?.lowercased() == "https" else {
                self?.showAlert(title: LegacyString("settings.invalid_url.title"), message: LegacyString("settings.invalid_doh_url.message"))
                return
            }
            UserDefaults.standard.set(value, forKey: LegacyNetworkSettings.dohCustomURLKey)
            self?.setDoH(enabled: true, provider: "custom", at: indexPath)
        })
        present(alert, animated: true)
    }

    private func setDoH(enabled: Bool, provider: String, at indexPath: IndexPath) {
        UserDefaults.standard.set(enabled, forKey: LegacyNetworkSettings.dohEnabledKey)
        UserDefaults.standard.set(provider, forKey: LegacyNetworkSettings.dohProviderKey)
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    private func showUserAgentEditor(at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: LegacyString("settings.default_user_agent"),
            message: LegacyString("settings.default_user_agent.message"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = LegacyNetworkSettings.builtInUserAgent
            field.text = LegacyNetworkSettings.hasUserAgentOverride ? LegacyNetworkSettings.defaultUserAgent : ""
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("settings.reset_to_default"), style: .destructive) { [weak self] _ in
            UserDefaults.standard.removeObject(forKey: LegacyNetworkSettings.userAgentKey)
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
        })
        alert.addAction(UIAlertAction(title: LegacyString("button.save"), style: .default) { [weak self] _ in
            let value = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: LegacyNetworkSettings.userAgentKey)
            } else {
                UserDefaults.standard.set(value, forKey: LegacyNetworkSettings.userAgentKey)
            }
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
        })
        present(alert, animated: true)
    }

    private func presentSheet(_ alert: UIAlertController, from indexPath: IndexPath) {
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: LegacyString("settings.clear_history"),
            message: LegacyString("clear_history.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("button.clear"), style: .destructive) { _ in
            LegacyHistoryStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func confirmClearLibrary() {
        let alert = UIAlertController(
            title: LegacyString("settings.clear_library"),
            message: LegacyString("clear_library.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LegacyString("button.clear"), style: .destructive) { _ in
            LegacyLibraryStore.shared.clear()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LegacyString("button.ok"), style: .default))
        present(alert, animated: true)
    }
}

final class LegacyRootViewController: UITableViewController {
    private let catalogClient = LegacySourceCatalogClient()
    private let repositoryStore = LegacySourceRepositoryStore.shared
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private let searchController = UISearchController(searchResultsController: nil)

    private var catalog: LegacySourceCatalog?
    private var allSources: [LegacySourceInfo] = []
    private var visibleSources: [LegacySourceInfo] = []
    private var installedSources: [AidokuRunnerLegacySource] = []
    private var loadingText = "Loading Aidoku Community Sources..."

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Browse"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = LegacyPalette.accent

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search sources"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadCatalog), for: .valueChanged)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Installed",
            style: .plain,
            target: self,
            action: #selector(showInstalledSources)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Repos",
            style: .plain,
            target: self,
            action: #selector(showRepositoryOptions)
        )

        reloadInstalledSources()
        reloadCatalog()
    }

    @objc private func reloadCatalog() {
        loadingText = "Loading Aidoku Community Sources..."
        tableView.reloadData()

        catalogClient.fetchCatalogs(from: repositoryStore.repositoryURLs) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshControl?.endRefreshing()

                switch result {
                    case .success(let catalog):
                        self.catalog = catalog
                        self.allSources = catalog.sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        self.applySearch()
                    case .failure(let error):
                        self.catalog = nil
                        self.allSources = []
                        self.visibleSources = []
                        self.loadingText = error.localizedDescription
                }

                self.tableView.reloadData()
            }
        }
    }

    private func applySearch() {
        let query = searchController.searchBar.text ?? ""
        visibleSources = allSources.filter { $0.matches(query: query) }
    }

    private func reloadInstalledSources() {
        installedSources = packageInstaller.loadInstalledSources()
        navigationItem.rightBarButtonItem?.title = installedSources.isEmpty ? "Installed" : "Installed (\(installedSources.count))"
    }

    @objc private func showInstalledSources() {
        if installedSources.isEmpty {
            showAlert(title: "Installed Sources", message: "No sources installed.")
            return
        }

        let viewController = LegacyInstalledSourcesViewController(sources: installedSources)
        navigationController?.pushViewController(viewController, animated: true)
    }

    @objc private func showRepositoryOptions() {
        let repos = repositoryStore.repositoryURLs.map { $0.absoluteString }.joined(separator: "\n")
        let alert = UIAlertController(title: "Source Repositories", message: repos, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Add Source Repo", style: .default) { [weak self] _ in
            self?.promptForRepository()
        })
        alert.addAction(UIAlertAction(title: "Refresh Repos", style: .default) { [weak self] _ in
            self?.reloadCatalog()
        })
        alert.addAction(UIAlertAction(title: "Reset to Community Repo", style: .destructive) { [weak self] _ in
            self?.repositoryStore.resetToDefault()
            self?.reloadCatalog()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }
        present(alert, animated: true)
    }

    private func promptForRepository() {
        let alert = UIAlertController(
            title: "Add Source Repo",
            message: "Paste an index.min.json URL or a GitHub owner/repo URL.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/sources/index.min.json"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard
                let self = self,
                let value = alert?.textFields?.first?.text,
                let url = self.repositoryStore.normalizedURL(from: value)
            else {
                self?.showAlert(title: "Invalid Repo", message: "Enter a valid source repository URL.")
                return
            }
            self.repositoryStore.add(url)
            self.reloadCatalog()
        })
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visibleSources.isEmpty ? 1 : visibleSources.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if let catalog = catalog {
            return "\(catalog.name) - \(visibleSources.count) sources"
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SourceCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText

        guard !visibleSources.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = loadingText
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let source = visibleSources[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
        if let iconURL = source.resolvedIconURL {
            LegacyImageLoader.shared.load(url: iconURL, targetHeight: 48) { image in
                guard
                    let visibleIndexPath = tableView.indexPath(for: cell),
                    visibleIndexPath == indexPath
                else { return }
                cell.imageView?.image = image ?? LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
                cell.setNeedsLayout()
            }
        }
        cell.textLabel?.text = source.name
        cell.detailTextLabel?.text = source.displaySubtitle
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !visibleSources.isEmpty else { return }
        showDetails(for: visibleSources[indexPath.row])
    }

    private func showDetails(for source: LegacySourceInfo) {
        let details = [
            source.id,
            "Version \(source.version)",
            source.languageText,
            source.ratingText,
            source.baseURL
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        let alert = UIAlertController(title: source.name, message: details, preferredStyle: .actionSheet)
        if let url = source.resolvedBaseURL {
            alert.addAction(UIAlertAction(title: "Browse Website", style: .default) { [weak self] _ in
                self?.openWebsite(url, title: source.name)
            })
        }
        alert.addAction(UIAlertAction(title: "Download Package", style: .default) { [weak self] _ in
            self?.download(source: source)
        })
        if let url = source.resolvedDownloadURL {
            alert.addAction(UIAlertAction(title: "Copy Package URL", style: .default) { _ in
                UIPasteboard.general.string = url.absoluteString
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: visibleSources.firstIndex { $0.id == source.id } ?? 0, section: 0))
        }

        present(alert, animated: true)
    }

    private func download(source: LegacySourceInfo) {
        loadingText = "Downloading \(source.name)..."
        tableView.reloadData()

        catalogClient.downloadPackage(for: source) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                    case .success(let packageURL):
                        self.installPackage(at: packageURL, sourceName: source.name)
                    case .failure(let error):
                        self.showAlert(title: "Download Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func installPackage(at packageURL: URL, sourceName: String) {
        loadingText = "Installing \(sourceName)..."
        tableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async {
            let installResult: Result<AidokuRunnerLegacySource, Error>
            do {
                installResult = .success(try self.packageInstaller.installPackage(at: packageURL))
            } catch {
                installResult = .failure(error)
            }

            DispatchQueue.main.async {
                switch installResult {
                    case .success(let source):
                        self.reloadInstalledSources()
                        LegacyImageLoader.shared.clear()
                        NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
                        self.showInstallSuccess(source)
                    case .failure(let error):
                        self.showAlert(title: "Install Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func showInstallSuccess(_ source: AidokuRunnerLegacySource) {
        let alert = UIAlertController(
            title: "Source Installed",
            message: "\(source.name) is ready in Installed Sources.",
            preferredStyle: .alert
        )
        if let url = source.urls.first {
            alert.addAction(UIAlertAction(title: "Browse Source", style: .default) { [weak self] _ in
                self?.openWebsite(url, title: source.name)
            })
        }
        alert.addAction(UIAlertAction(title: "Open Source", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(LegacySourceMenuViewController(source: source), animated: true)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    fileprivate func openWebsite(_ url: URL, title: String) {
        let viewController = LegacySourceWebViewController(url: url, title: title)
        navigationController?.pushViewController(viewController, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension LegacyRootViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        applySearch()
        tableView.reloadData()
    }
}

final class LegacyInstalledSourcesViewController: UITableViewController {
    private let repositoryStore = LegacySourceRepositoryStore.shared
    private let packageInstaller = AidokuRunnerLegacyPackageInstaller()
    private var sources: [AidokuRunnerLegacySource]
    private var observer: NSObjectProtocol?

    init(sources: [AidokuRunnerLegacySource]? = nil) {
        self.sources = (sources ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(style: .plain)
        title = "Sources"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
        navigationItem.largeTitleDisplayMode = .automatic
        navigationController?.navigationBar.prefersLargeTitles = true
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadSources), for: .valueChanged)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Repos",
            style: .plain,
            target: self,
            action: #selector(showRepositoryOptions)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Batch Search", style: .plain, target: self, action: #selector(openBatchSearch)),
            UIBarButtonItem(title: "Update", style: .plain, target: self, action: #selector(updateInstalledSources))
        ]
        observer = NotificationCenter.default.addObserver(
            forName: .legacyInstalledSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadSources()
        }
        if sources.isEmpty {
            reloadSources()
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func reloadSources() {
        sources = packageInstaller.loadInstalledSources()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshControl?.endRefreshing()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sources.isEmpty ? 1 : sources.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "InstalledSourceCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "InstalledSourceCell")
        guard !sources.isEmpty else {
            cell.backgroundColor = LegacyPalette.panel
            cell.textLabel?.textColor = LegacyPalette.primaryText
            cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
            cell.imageView?.image = nil
            cell.textLabel?.text = "No sources installed."
            cell.detailTextLabel?.text = "Open Browse to install Aidoku Community sources."
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        let source = sources[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.imageView?.image = source.imageUrl.flatMap {
            UIImage(contentsOfFile: $0.path)
        } ?? LegacyImageLoader.placeholder(size: CGSize(width: 36, height: 36))
        cell.textLabel?.text = source.name
        cell.detailTextLabel?.text = "\(source.key)  v\(source.version)  \(source.languages.joined(separator: ", "))"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sources.isEmpty else { return }
        let source = sources[indexPath.row]
        navigationController?.pushViewController(LegacySourceMenuViewController(source: source), animated: true)
    }

    @objc private func openBatchSearch() {
        let loadedSources = sources.isEmpty ? packageInstaller.loadInstalledSources() : sources
        navigationController?.pushViewController(
            LegacyBatchMangaSearchViewController(sources: loadedSources),
            animated: true
        )
    }

    @objc private func updateInstalledSources() {
        guard !(sources.isEmpty ? packageInstaller.loadInstalledSources() : sources).isEmpty else {
            showAlert(title: "No Sources", message: "Install sources before checking for updates.")
            return
        }
        LegacySourceUpdateManager.shared.updateInstalledSources(automatic: false, progress: { [weak self] message in
            self?.navigationItem.prompt = message
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.reloadSources()
            if let error = result.error {
                self.showAlert(title: "Update Failed", message: error.localizedDescription)
            } else if result.skipped {
                self.showAlert(title: "Update Skipped", message: "A source update is already running.")
            } else if result.updatedCount == 0 && result.failedCount == 0 {
                self.showAlert(title: "Sources Current", message: "Installed sources are already up to date.")
            } else {
                let failedText = result.failedCount > 0 ? " \(result.failedCount) failed." : ""
                self.showAlert(
                    title: "Sources Updated",
                    message: "Updated \(result.updatedCount) source package(s).\(failedText)"
                )
            }
        })
    }

    @objc private func showRepositoryOptions() {
        let repos = repositoryStore.repositoryURLs.map { $0.absoluteString }.joined(separator: "\n")
        let alert = UIAlertController(title: "Source Repositories", message: repos, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Add Source Repo", style: .default) { [weak self] _ in
            self?.promptForRepository()
        })
        alert.addAction(UIAlertAction(title: "Check Source Updates", style: .default) { [weak self] _ in
            self?.updateInstalledSources()
        })
        alert.addAction(UIAlertAction(title: "Reset to Community Repo", style: .destructive) { [weak self] _ in
            self?.repositoryStore.resetToDefault()
            self?.updateInstalledSources()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }
        present(alert, animated: true)
    }

    private func promptForRepository() {
        let alert = UIAlertController(
            title: "Add Source Repo",
            message: "Paste an index.min.json URL or a GitHub owner/repo URL.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/sources/index.min.json"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard
                let self = self,
                let value = alert?.textFields?.first?.text,
                let url = self.repositoryStore.normalizedURL(from: value)
            else {
                self?.showAlert(title: "Invalid Repo", message: "Enter a valid source repository URL.")
                return
            }
            self.repositoryStore.add(url)
            if self.sources.isEmpty {
                self.showAlert(title: "Repo Added", message: "Open Browse to install sources from this repository.")
            } else {
                self.updateInstalledSources()
            }
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyBatchMangaSearchViewController: UITableViewController {
    private struct Section {
        let source: AidokuRunnerLegacySource
        var entries: [AidokuRunnerLegacyManga]
        var error: String?
    }

    private let sources: [AidokuRunnerLegacySource]
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounceTimer: Timer?
    private var sections: [Section] = []
    private var isLoading = false
    private var message = "Enter a search term."

    init(sources: [AidokuRunnerLegacySource]) {
        self.sources = sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(style: .plain)
        title = "Batch Search"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        searchController.searchBar.placeholder = "Search all installed sources"
        searchController.searchBar.delegate = self
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.isEmpty ? 1 : sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !sections.isEmpty else { return 1 }
        let section = sections[section]
        if !section.entries.isEmpty { return section.entries.count }
        return section.error == nil ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !sections.isEmpty else { return nil }
        let section = sections[section]
        let count = section.entries.count
        return count == 0 ? section.source.name : "\(section.source.name) (\(count))"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BatchSearchCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "BatchSearchCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2

        guard !sections.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Searching..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let section = sections[indexPath.section]
        guard !section.entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = "Search failed"
            cell.detailTextLabel?.text = section.error
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let manga = section.entries[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: manga.coverURLCandidates(relativeTo: section.source.urls.first),
            source: section.source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
        cell.textLabel?.text = manga.title
        cell.detailTextLabel?.text = manga.legacySummaryText ?? section.source.name
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sections.isEmpty, sections[indexPath.section].entries.indices.contains(indexPath.row) else { return }
        let section = sections[indexPath.section]
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: section.source, manga: section.entries[indexPath.row]),
            animated: true
        )
    }

    private func search(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            sections = []
            isLoading = false
            message = trimmedQuery.isEmpty ? "Enter a search term." : "Keep typing..."
            tableView.reloadData()
            return
        }
        guard !sources.isEmpty else {
            sections = []
            isLoading = false
            message = "No sources installed."
            tableView.reloadData()
            return
        }

        isLoading = true
        sections = []
        message = "Searching..."
        tableView.reloadData()

        let currentQuery = trimmedQuery
        let group = DispatchGroup()
        var collected: [Section] = []
        let lock = NSLock()

        for source in sources {
            group.enter()
            source.runner.getSearchMangaList(query: currentQuery, page: 1, filters: []) { result in
                let section: Section?
                switch result {
                    case .success(let page):
                        section = page.entries.isEmpty ? nil : Section(source: source, entries: page.entries, error: nil)
                    case .failure(let error):
                        section = Section(source: source, entries: [], error: error.localizedDescription)
                }
                if let section = section {
                    lock.lock()
                    collected.append(section)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let latestQuery = self.searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard latestQuery == currentQuery else { return }
            self.sections = collected.sorted { lhs, rhs in
                lhs.source.name.localizedCaseInsensitiveCompare(rhs.source.name) == .orderedAscending
            }
            self.isLoading = false
            self.message = self.sections.isEmpty ? "No manga found." : ""
            self.tableView.reloadData()
        }
    }
}

extension LegacyBatchMangaSearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        search(query: searchBar.text ?? "")
    }
}

extension LegacyBatchMangaSearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchDebounceTimer?.invalidate()
        let query = searchController.searchBar.text ?? ""
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            sections = []
            isLoading = false
            message = trimmedQuery.isEmpty ? "Enter a search term." : "Keep typing..."
            tableView.reloadData()
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            self?.search(query: query)
        }
    }
}

final class LegacyMangaMigrationViewController: UITableViewController {
    private struct Section {
        let source: AidokuRunnerLegacySource
        var entries: [AidokuRunnerLegacyManga]
        var error: String?
    }

    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let sources: [AidokuRunnerLegacySource]
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounceTimer: Timer?
    private var sections: [Section] = []
    private var isLoading = false
    private var message = LegacyString("migration.search.empty_term")

    init(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga) {
        self.source = source
        self.manga = manga
        self.sources = AidokuRunnerLegacyPackageInstaller()
            .loadInstalledSources()
            .filter { $0.key != source.key }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(style: .plain)
        title = LegacyString("migration.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        searchController.searchBar.placeholder = LegacyString("migration.search.placeholder")
        searchController.searchBar.text = manga.title
        searchController.searchBar.delegate = self
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        search(query: manga.title)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.isEmpty ? 1 : sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !sections.isEmpty else { return 1 }
        let section = sections[section]
        if !section.entries.isEmpty { return section.entries.count }
        return section.error == nil ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !sections.isEmpty else { return nil }
        let section = sections[section]
        let count = section.entries.count
        return count == 0 ? section.source.name : String(format: LegacyString("migration.section.count"), section.source.name, count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MigrationSearchCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "MigrationSearchCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2

        guard !sections.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? LegacyString("migration.search.searching") : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let section = sections[indexPath.section]
        guard !section.entries.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = LegacyString("migration.search.failed")
            cell.detailTextLabel?.text = section.error
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let result = section.entries[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: result.coverURLCandidates(relativeTo: section.source.urls.first),
            source: section.source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
        cell.textLabel?.text = result.title
        cell.detailTextLabel?.text = result.legacySummaryText ?? section.source.name
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sections.isEmpty, sections[indexPath.section].entries.indices.contains(indexPath.row) else { return }
        let section = sections[indexPath.section]
        let targetManga = section.entries[indexPath.row]
        presentActions(targetSource: section.source, targetManga: targetManga, sourceView: tableView.cellForRow(at: indexPath))
    }

    private func presentActions(
        targetSource: AidokuRunnerLegacySource,
        targetManga: AidokuRunnerLegacyManga,
        sourceView: UIView?
    ) {
        let alert = UIAlertController(title: targetManga.title, message: targetSource.name, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: LegacyString("migration.copy"), style: .default) { [weak self] _ in
            self?.loadAndApply(targetSource: targetSource, targetManga: targetManga, mode: .copy)
        })
        alert.addAction(UIAlertAction(title: LegacyString("migration.migrate"), style: .default) { [weak self] _ in
            self?.loadAndApply(targetSource: targetSource, targetManga: targetManga, mode: .migrate)
        })
        alert.addAction(UIAlertAction(title: LegacyString("migration.show_entry"), style: .default) { [weak self] _ in
            self?.showEntry(source: targetSource, manga: targetManga)
        })
        alert.addAction(UIAlertAction(title: LegacyString("button.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView ?? view
            popover.sourceRect = (sourceView ?? view).bounds
        }
        present(alert, animated: true)
    }

    private func loadAndApply(
        targetSource: AidokuRunnerLegacySource,
        targetManga: AidokuRunnerLegacyManga,
        mode: LegacyMangaMigrationMode
    ) {
        navigationItem.prompt = LegacyString("migration.loading_details")
        targetSource.runner.getMangaUpdate(manga: targetManga, needsDetails: true, needsChapters: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.navigationItem.prompt = nil
                switch result {
                    case .success(let updatedManga):
                        let mergedManga = targetManga.mergedWithUpdate(updatedManga)
                        LegacyMangaMigrationEngine.apply(
                            fromSource: self.source,
                            fromManga: self.manga,
                            toSource: targetSource,
                            toManga: mergedManga,
                            mode: mode
                        )
                        self.presentCompletion(mode: mode, targetSource: targetSource, targetManga: mergedManga)
                    case .failure(let error):
                        self.showAlert(title: LegacyString("migration.failed.title"), message: error.localizedDescription)
                }
            }
        }
    }

    private func presentCompletion(
        mode: LegacyMangaMigrationMode,
        targetSource: AidokuRunnerLegacySource,
        targetManga: AidokuRunnerLegacyManga
    ) {
        let title = mode == .copy
            ? LegacyString("migration.copied.title")
            : LegacyString("migration.completed.title")
        let message = mode == .copy
            ? LegacyString("migration.copied.message")
            : LegacyString("migration.completed.message")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LegacyString("migration.show_entry"), style: .default) { [weak self] _ in
            self?.showEntryAfterCompletion(mode: mode, source: targetSource, manga: targetManga)
        })
        alert.addAction(UIAlertAction(title: LegacyString("button.ok"), style: .default) { [weak self] _ in
            if mode == .migrate {
                self?.replaceCurrentFlowWithTarget(source: targetSource, manga: targetManga)
            }
        })
        present(alert, animated: true)
    }

    private func showEntryAfterCompletion(
        mode: LegacyMangaMigrationMode,
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga
    ) {
        if mode == .migrate {
            replaceCurrentFlowWithTarget(source: source, manga: manga)
        } else {
            showEntry(source: source, manga: manga)
        }
    }

    private func showEntry(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga) {
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: manga),
            animated: true
        )
    }

    private func replaceCurrentFlowWithTarget(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga) {
        guard let navigationController = navigationController else { return }
        var controllers = navigationController.viewControllers
        if !controllers.isEmpty {
            controllers.removeLast()
        }
        if !controllers.isEmpty {
            controllers.removeLast()
        }
        controllers.append(LegacyMangaDetailViewController(source: source, manga: manga))
        navigationController.setViewControllers(controllers, animated: true)
    }

    private func search(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            sections = []
            isLoading = false
            message = trimmedQuery.isEmpty ? LegacyString("migration.search.empty_term") : LegacyString("migration.search.keep_typing")
            tableView.reloadData()
            return
        }
        guard !sources.isEmpty else {
            sections = []
            isLoading = false
            message = LegacyString("migration.no_sources")
            tableView.reloadData()
            return
        }

        isLoading = true
        sections = []
        message = LegacyString("migration.search.searching")
        tableView.reloadData()

        let currentQuery = trimmedQuery
        let group = DispatchGroup()
        var collected: [Section] = []
        let lock = NSLock()

        for source in sources {
            group.enter()
            source.runner.getSearchMangaList(query: currentQuery, page: 1, filters: []) { result in
                let section: Section?
                switch result {
                    case .success(let page):
                        section = page.entries.isEmpty ? nil : Section(source: source, entries: page.entries, error: nil)
                    case .failure(let error):
                        section = Section(source: source, entries: [], error: error.localizedDescription)
                }
                if let section = section {
                    lock.lock()
                    collected.append(section)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let latestQuery = self.searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard latestQuery == currentQuery else { return }
            self.sections = collected.sorted { lhs, rhs in
                lhs.source.name.localizedCaseInsensitiveCompare(rhs.source.name) == .orderedAscending
            }
            self.isLoading = false
            self.message = self.sections.isEmpty ? LegacyString("migration.search.no_results") : ""
            self.tableView.reloadData()
        }
    }

    private func showAlert(title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LegacyString("button.ok"), style: .default))
        present(alert, animated: true)
    }
}

extension LegacyMangaMigrationViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        search(query: searchBar.text ?? "")
    }
}

extension LegacyMangaMigrationViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchDebounceTimer?.invalidate()
        let query = searchController.searchBar.text ?? ""
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            sections = []
            isLoading = false
            message = trimmedQuery.isEmpty ? LegacyString("migration.search.empty_term") : LegacyString("migration.search.keep_typing")
            tableView.reloadData()
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            self?.search(query: query)
        }
    }
}

final class LegacySourceMenuViewController: UITableViewController {
    private enum Row {
        case home
        case search
        case settings
        case listing(AidokuRunnerLegacyListing)
        case website(URL)
        case message(title: String, subtitle: String?)
    }

    private let source: AidokuRunnerLegacySource
    private var rows: [Row] = []

    init(source: AidokuRunnerLegacySource) {
        self.source = source
        super.init(style: .grouped)
        title = source.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        rows = []
        if source.runner.features.providesHome {
            rows.append(.home)
        }
        rows.append(.search)
        if source.hasConfigurableSettings {
            rows.append(.settings)
        }
        rows.append(contentsOf: source.staticListings.map { .listing($0) })
        if source.runner.features.dynamicListings {
            rows.append(.message(title: "Loading Listings...", subtitle: nil))
            loadDynamicListings()
        }
        if let url = source.urls.first {
            rows.append(.website(url))
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceMenuCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SourceMenuCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch rows[indexPath.row] {
            case .home:
                cell.textLabel?.text = "Home"
                cell.detailTextLabel?.text = "Run get_home"
            case .search:
                cell.textLabel?.text = "Search Manga"
                cell.detailTextLabel?.text = "Run get_search_manga_list"
            case .settings:
                cell.textLabel?.text = "Source Settings"
                cell.detailTextLabel?.text = "Languages, content ratings, and source options"
            case .listing(let listing):
                cell.textLabel?.text = listing.name
                cell.detailTextLabel?.text = "Run get_manga_list"
            case .website(let url):
                cell.textLabel?.text = "Browse Website"
                cell.detailTextLabel?.text = url.absoluteString
            case .message(let title, let subtitle):
                cell.textLabel?.text = title
                cell.detailTextLabel?.text = subtitle
                cell.accessoryType = .none
                cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
            case .home:
                navigationController?.pushViewController(LegacySourceHomeViewController(source: source), animated: true)
            case .search:
                navigationController?.pushViewController(LegacyMangaListViewController(source: source, listing: nil), animated: true)
            case .settings:
                navigationController?.pushViewController(LegacySourceSettingsViewController(source: source), animated: true)
            case .listing(let listing):
                navigationController?.pushViewController(LegacyMangaListViewController(source: source, listing: listing), animated: true)
            case .website(let url):
                openWebsite(fallbackURL: url)
            case .message:
                return
        }
    }

    private func openWebsite(fallbackURL: URL) {
        guard source.runner.features.providesBaseUrl else {
            navigationController?.pushViewController(LegacySourceWebViewController(url: fallbackURL, title: source.name), animated: true)
            return
        }
        source.runner.getBaseUrl { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let url: URL
                if case .success(let baseURL?) = result {
                    url = baseURL
                } else {
                    url = fallbackURL
                }
                self.navigationController?.pushViewController(LegacySourceWebViewController(url: url, title: self.source.name), animated: true)
            }
        }
    }

    private func loadDynamicListings() {
        source.runner.getListings { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rows.removeAll {
                    if case .message(let title, _) = $0 {
                        return title == "Loading Listings..." || title == "Listings Unavailable"
                    }
                    return false
                }
                switch result {
                    case .success(let listings):
                        let existing = Set(self.source.staticListings.map { $0.id })
                        let dynamicRows = listings
                            .filter { !existing.contains($0.id) }
                            .map { Row.listing($0) }
                        let prefixCount = self.fixedPrefixCount
                        let insertIndex = min(prefixCount + self.source.staticListings.count, self.rows.count)
                        self.rows.insert(contentsOf: dynamicRows, at: insertIndex)
                    case .failure(let error):
                        let prefixCount = self.fixedPrefixCount
                        self.rows.insert(
                            .message(title: "Listings Unavailable", subtitle: error.localizedDescription),
                            at: min(prefixCount + self.source.staticListings.count, self.rows.count)
                        )
                }
                self.tableView.reloadData()
            }
        }
    }

    private var fixedPrefixCount: Int {
        var count = 1 // Search
        if source.runner.features.providesHome {
            count += 1
        }
        if source.hasConfigurableSettings {
            count += 1
        }
        return count
    }
}

final class LegacySourceSettingsViewController: UITableViewController {
    private enum LoginKeys {
        static let loggedInValue = "logged_in"
        static let usernameSuffix = ".username"
        static let passwordSuffix = ".password"
        static let cookieKeysSuffix = ".keys"
        static let cookieValuesSuffix = ".values"
        static let localStoragePrefix = ".ls."
    }

    private enum Row {
        case languages
        case baseURL
        case setting(AidokuRunnerLegacySettingItem)
    }

    private struct Section {
        let title: String?
        let rows: [Row]
    }

    private let source: AidokuRunnerLegacySource
    private var sections: [Section] = []
    private var settings: [AidokuRunnerLegacySettingItem] = []

    init(source: AidokuRunnerLegacySource) {
        self.source = source
        self.settings = source.staticSettings
        super.init(style: .grouped)
        title = "Source Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        buildSections()
        loadSettings()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceSettingCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SourceSettingCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator

        switch sections[indexPath.section].rows[indexPath.row] {
            case .languages:
                cell.textLabel?.text = "Languages"
                cell.detailTextLabel?.text = selectedLanguages().joined(separator: ", ")
            case .baseURL:
                cell.textLabel?.text = "Base URL"
                cell.detailTextLabel?.text = currentBaseURL()
            case .setting(let setting):
                cell.textLabel?.text = settingTitle(setting)
                cell.detailTextLabel?.text = detailText(for: setting)
                if setting.type == "switch" || setting.type == "toggle" {
                    cell.accessoryType = boolValue(for: setting) ? .checkmark : .none
                }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
            case .languages:
                openLanguagePicker()
            case .baseURL:
                openBaseURLPicker()
            case .setting(let setting):
                edit(setting)
        }
    }

    private func buildSections() {
        sections.removeAll()
        var sourceRows: [Row] = []
        if source.languages.count > 1 {
            sourceRows.append(.languages)
        }
        if (source.config?.allowsBaseUrlSelect ?? false) && source.urls.count > 1 {
            sourceRows.append(.baseURL)
        }
        if !sourceRows.isEmpty {
            sections.append(Section(title: "Source", rows: sourceRows))
        }

        var looseRows: [Row] = []
        for setting in settings {
            if setting.type == "group" || setting.type == "page" {
                let rows = settingRows(in: setting.items ?? [])
                if !rows.isEmpty {
                    sections.append(Section(title: setting.title, rows: rows))
                }
            } else if isEditable(setting) {
                looseRows.append(.setting(setting))
            }
        }
        if !looseRows.isEmpty {
            sections.append(Section(title: "Settings", rows: looseRows))
        }
    }

    private func loadSettings() {
        guard source.runner.features.dynamicSettings else { return }
        source.getSettings { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                    case .success(let settings):
                        self.settings = settings
                        self.buildSections()
                        self.tableView.reloadData()
                    case .failure(let error):
                        self.showMessage(title: "Settings Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func settingRows(in settings: [AidokuRunnerLegacySettingItem]) -> [Row] {
        var rows: [Row] = []
        for setting in settings {
            if setting.type == "group" || setting.type == "page" {
                rows.append(contentsOf: settingRows(in: setting.items ?? []))
            } else if isEditable(setting) {
                rows.append(.setting(setting))
            }
        }
        return rows
    }

    private func isEditable(_ setting: AidokuRunnerLegacySettingItem) -> Bool {
        if setting.type == "link" {
            return resolvedURL(for: setting) != nil
        }
        if setting.type == "button" {
            return setting.notification != nil || setting.action != nil
        }
        guard setting.key != nil else { return false }
        switch setting.type {
            case "select", "segment", "multi-select", "multi-single-select", "switch", "toggle", "text", "stepper", "editable-list", "login":
                return true
            default:
                return false
        }
    }

    private func openLanguagePicker() {
        let allowsMultiple = (source.config?.languageSelectType ?? .multiple) != .single
        let selected = Set(selectedLanguages())
        let options = source.languages.map { language -> (label: String, value: String) in
            let label = Locale.current.localizedString(forIdentifier: language) ?? language
            return (label, language)
        }
        let picker = LegacyFilterOptionPickerViewController(
            title: "Languages",
            options: options,
            selectedValues: selected,
            allowsMultiple: allowsMultiple,
            allowsExclusion: false
        ) { [weak self] selected, _ in
            guard let self = self else { return }
            if allowsMultiple {
                UserDefaults.standard.set(Array(selected).sorted(), forKey: "\(self.source.key).languages")
            } else if let first = selected.first {
                UserDefaults.standard.set(first, forKey: "\(self.source.key).language")
                UserDefaults.standard.set([first], forKey: "\(self.source.key).languages")
            }
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func openBaseURLPicker() {
        let options = source.urls.map { ($0.absoluteString, $0.absoluteString) }
        let picker = LegacyFilterOptionPickerViewController(
            title: "Base URL",
            options: options,
            selectedValues: Set([currentBaseURL()]),
            allowsMultiple: false,
            allowsExclusion: false
        ) { [weak self] selected, _ in
            guard let self = self, let value = selected.first else { return }
            UserDefaults.standard.set(value, forKey: "\(self.source.key).url")
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func edit(_ setting: AidokuRunnerLegacySettingItem) {
        switch setting.type {
            case "link":
                openLink(setting)
            case "button":
                notifySettingChanged(setting)
            case "switch", "toggle":
                guard let key = setting.key else { return }
                let defaultsKey = "\(source.key).\(key)"
                UserDefaults.standard.set(!boolValue(for: setting), forKey: defaultsKey)
                notifySettingChanged(setting)
                tableView.reloadData()
            case "select", "segment":
                openSettingPicker(setting: setting, allowsMultiple: false)
            case "multi-select", "multi-single-select":
                openSettingPicker(setting: setting, allowsMultiple: true)
            case "text", "stepper":
                editText(setting: setting)
            case "editable-list":
                editList(setting: setting)
            case "login":
                editLogin(setting)
            default:
                return
        }
    }

    private func openSettingPicker(setting: AidokuRunnerLegacySettingItem, allowsMultiple: Bool) {
        guard let key = setting.key, setting.values?.isEmpty == false else { return }
        let defaultsKey = "\(source.key).\(key)"
        let selected: Set<String> = allowsMultiple
            ? Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            : Set([UserDefaults.standard.string(forKey: defaultsKey) ?? ""])
        let picker = LegacyFilterOptionPickerViewController(
            title: settingTitle(setting),
            options: options(for: setting),
            selectedValues: selected,
            allowsMultiple: allowsMultiple,
            allowsExclusion: false
        ) { [weak self] selected, _ in
            guard let self = self else { return }
            if allowsMultiple {
                UserDefaults.standard.set(Array(selected).sorted(), forKey: defaultsKey)
            } else if let value = selected.first {
                UserDefaults.standard.set(value, forKey: defaultsKey)
            }
            self.notifySettingChanged(setting)
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func editText(setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        let alert = UIAlertController(title: settingTitle(setting), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = self.stringValue(forKey: defaultsKey)
            if setting.type == "stepper" {
                textField.keyboardType = .decimalPad
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text else { return }
            if setting.type == "stepper", let number = Double(text) {
                UserDefaults.standard.set(number, forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(text, forKey: defaultsKey)
            }
            self.notifySettingChanged(setting)
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func editList(setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        let alert = UIAlertController(
            title: settingTitle(setting),
            message: "Enter comma-separated values.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).joined(separator: ", ")
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text else { return }
            let values = text
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            UserDefaults.standard.set(values, forKey: defaultsKey)
            self.notifySettingChanged(setting)
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func editLogin(_ setting: AidokuRunnerLegacySettingItem) {
        guard setting.key != nil else { return }
        if isLoggedIn(setting) {
            confirmLogout(setting)
            return
        }

        switch setting.method?.lowercased() {
            case "web", "oauth":
                openWebLogin(setting)
            default:
                openBasicLogin(setting)
        }
    }

    private func openBasicLogin(_ setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        let alert = UIAlertController(
            title: settingTitle(setting),
            message: setting.subtitle ?? "Enter your source account credentials.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = UserDefaults.standard.string(forKey: defaultsKey + LoginKeys.usernameSuffix)
            textField.placeholder = (setting.useEmail ?? false) ? "Email" : "Username"
            textField.keyboardType = (setting.useEmail ?? false) ? .emailAddress : .default
            textField.textContentType = (setting.useEmail ?? false) ? .emailAddress : .username
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addTextField { textField in
            textField.text = UserDefaults.standard.string(forKey: defaultsKey + LoginKeys.passwordSuffix)
            textField.placeholder = "Password"
            textField.textContentType = .password
            textField.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak self, weak alert] _ in
            guard
                let self = self,
                let textFields = alert?.textFields,
                textFields.count >= 2,
                let username = textFields[0].text,
                let password = textFields[1].text,
                !username.isEmpty,
                !password.isEmpty
            else { return }
            self.finishBasicLogin(setting: setting, username: username, password: password)
        })
        present(alert, animated: true)
    }

    private func finishBasicLogin(setting: AidokuRunnerLegacySettingItem, username: String, password: String) {
        guard let key = setting.key else { return }
        source.runner.handleBasicLogin(key: key, username: username, password: password) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(true):
                    let defaultsKey = "\(self.source.key).\(key)"
                    UserDefaults.standard.set(username, forKey: defaultsKey + LoginKeys.usernameSuffix)
                    UserDefaults.standard.set(password, forKey: defaultsKey + LoginKeys.passwordSuffix)
                    UserDefaults.standard.set(LoginKeys.loggedInValue, forKey: defaultsKey)
                    self.notifySettingChanged(setting)
                    self.tableView.reloadData()
                case .success(false):
                    self.showMessage(title: "Login Failed", message: "The source rejected the credentials.")
                case .failure(let error):
                    self.showMessage(title: "Login Failed", message: error.localizedDescription)
            }
        }
    }

    private func openWebLogin(_ setting: AidokuRunnerLegacySettingItem) {
        guard let url = resolvedURL(for: setting) else {
            showMessage(title: "Login Failed", message: "This source did not provide a login URL.")
            return
        }
        let controller = LegacySourceWebViewController(
            url: url,
            title: settingTitle(setting),
            localStorageKeys: setting.localStorageKeys ?? []
        ) { [weak self] result in
            self?.finishWebLogin(setting: setting, result: result)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func finishWebLogin(setting: AidokuRunnerLegacySettingItem, result: LegacyWebLoginResult) {
        guard let key = setting.key else { return }
        guard !result.cookies.isEmpty || !result.localStorage.isEmpty else {
            showMessage(title: "Login Failed", message: "No login cookies or local storage values were found.")
            return
        }
        source.runner.handleWebLogin(key: key, cookies: result.cookies) { [weak self] loginResult in
            guard let self = self else { return }
            switch loginResult {
                case .success(true):
                    let defaultsKey = "\(self.source.key).\(key)"
                    let cookieKeys = result.cookies.keys.sorted()
                    let cookieValues = cookieKeys.map { result.cookies[$0] ?? "" }
                    UserDefaults.standard.set(cookieKeys, forKey: defaultsKey + LoginKeys.cookieKeysSuffix)
                    UserDefaults.standard.set(cookieValues, forKey: defaultsKey + LoginKeys.cookieValuesSuffix)
                    for (storageKey, storageValue) in result.localStorage {
                        UserDefaults.standard.set(storageValue, forKey: defaultsKey + LoginKeys.localStoragePrefix + storageKey)
                    }
                    UserDefaults.standard.set(LoginKeys.loggedInValue, forKey: defaultsKey)
                    self.notifySettingChanged(setting)
                    self.tableView.reloadData()
                    self.navigationController?.popViewController(animated: true)
                case .success(false):
                    self.showMessage(title: "Login Failed", message: "The source did not accept the web login.")
                case .failure(let error):
                    self.showMessage(title: "Login Failed", message: error.localizedDescription)
            }
        }
    }

    private func confirmLogout(_ setting: AidokuRunnerLegacySettingItem) {
        let alert = UIAlertController(
            title: setting.logoutTitle ?? "Log Out",
            message: "Remove saved login data for this source?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.logout(setting)
        })
        present(alert, animated: true)
    }

    private func logout(_ setting: AidokuRunnerLegacySettingItem) {
        guard let key = setting.key else { return }
        let defaultsKey = "\(source.key).\(key)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.usernameSuffix)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.passwordSuffix)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.cookieKeysSuffix)
        UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.cookieValuesSuffix)
        for localStorageKey in setting.localStorageKeys ?? [] {
            UserDefaults.standard.removeObject(forKey: defaultsKey + LoginKeys.localStoragePrefix + localStorageKey)
        }
        notifySettingChanged(setting)
        tableView.reloadData()
    }

    private func openLink(_ setting: AidokuRunnerLegacySettingItem) {
        guard let url = resolvedURL(for: setting) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func notifySettingChanged(_ setting: AidokuRunnerLegacySettingItem) {
        if let action = setting.action {
            NotificationCenter.default.post(name: Notification.Name(action), object: nil)
        }
        if let notification = setting.notification {
            source.runner.handleNotification(notification: notification) { result in
                if case .failure(let error) = result {
                    print("[AidokuLegacy] setting notification failed: \(error)")
                }
            }
            NotificationCenter.default.post(name: Notification.Name(notification), object: nil)
        }
        for refresh in setting.refreshes ?? [] {
            NotificationCenter.default.post(name: Notification.Name("refresh-\(refresh)"), object: nil)
        }
    }

    private func isLoggedIn(_ setting: AidokuRunnerLegacySettingItem) -> Bool {
        guard let key = setting.key else { return false }
        return !(UserDefaults.standard.string(forKey: "\(source.key).\(key)") ?? "").isEmpty
    }

    private func resolvedURL(for setting: AidokuRunnerLegacySettingItem) -> URL? {
        if let urlString = setting.url, let url = URL(string: urlString) {
            return url
        }
        if
            let urlKey = setting.urlKey,
            let urlString = UserDefaults.standard.string(forKey: "\(source.key).\(urlKey)") ?? (urlKey == "url" ? currentBaseURL() : nil),
            let url = URL(string: urlString)
        {
            return url
        }
        return source.urls.first
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (navigationController?.topViewController ?? self).present(alert, animated: true)
    }

    private func selectedLanguages() -> [String] {
        if (source.config?.languageSelectType ?? .multiple) == .single,
           let language = UserDefaults.standard.string(forKey: "\(source.key).language"),
           !language.isEmpty {
            return [language]
        }
        return UserDefaults.standard.stringArray(forKey: "\(source.key).languages") ?? []
    }

    private func currentBaseURL() -> String {
        return UserDefaults.standard.string(forKey: "\(source.key).url") ?? source.urls.first?.absoluteString ?? ""
    }

    private func boolValue(for setting: AidokuRunnerLegacySettingItem) -> Bool {
        guard let key = setting.key else { return false }
        return UserDefaults.standard.bool(forKey: "\(source.key).\(key)")
    }

    private func detailText(for setting: AidokuRunnerLegacySettingItem) -> String? {
        if setting.type == "link" {
            return setting.subtitle ?? resolvedURL(for: setting)?.host
        }
        if setting.type == "button" {
            return setting.subtitle
        }
        guard let key = setting.key else { return nil }
        let defaultsKey = "\(source.key).\(key)"
        switch setting.type {
            case "switch", "toggle":
                return boolValue(for: setting) ? "On" : "Off"
            case "login":
                return isLoggedIn(setting) ? "Logged in" : setting.subtitle ?? "Not logged in"
            case "multi-select", "multi-single-select", "editable-list":
                let values = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
                return values.isEmpty ? "None" : values.joined(separator: ", ")
            case "select", "segment":
                let value = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
                return label(for: value, in: setting) ?? value
            default:
                return stringValue(forKey: defaultsKey)
        }
    }

    private func stringValue(forKey key: String) -> String {
        if let value = UserDefaults.standard.string(forKey: key) {
            return value
        }
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func options(for setting: AidokuRunnerLegacySettingItem) -> [(label: String, value: String)] {
        let values = setting.values ?? []
        let titles = setting.titles ?? []
        return values.enumerated().map { index, value in
            let title = index < titles.count ? titles[index] : value
            return (title, value)
        }
    }

    private func label(for value: String, in setting: AidokuRunnerLegacySettingItem) -> String? {
        return options(for: setting).first { $0.value == value }?.label
    }

    private func settingTitle(_ setting: AidokuRunnerLegacySettingItem) -> String {
        return setting.title ?? setting.key ?? setting.type
    }
}

final class LegacySourceHomeViewController: UITableViewController {
    private enum Row {
        case header(title: String?, subtitle: String?)
        case link(AidokuRunnerLegacyHomeLink)
        case manga(AidokuRunnerLegacyManga)
        case chapter(AidokuRunnerLegacyMangaWithChapter)
        case filter(AidokuRunnerLegacyHomeFilterItem)
        case listing(AidokuRunnerLegacyListing, title: String)
    }

    private let source: AidokuRunnerLegacySource
    private var rows: [Row] = []
    private var message = "Loading home..."
    private var isLoading = false

    init(source: AidokuRunnerLegacySource) {
        self.source = source
        super.init(style: .plain)
        title = source.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(loadHome), for: .valueChanged)
        loadHome()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.isEmpty ? 1 : rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HomeCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "HomeCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        cell.imageView?.image = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default

        guard !rows.isEmpty else {
            cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
            cell.textLabel?.text = isLoading ? "Loading..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        switch rows[indexPath.row] {
            case .header(let title, let subtitle):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
                cell.textLabel?.text = title ?? "Home"
                cell.detailTextLabel?.text = subtitle
                cell.accessoryType = .none
                cell.selectionStyle = .none
            case .link(let link):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = link.title
                cell.detailTextLabel?.text = link.subtitle ?? detailText(for: link.value)
                cell.accessoryType = link.value == nil ? .none : .disclosureIndicator
                cell.selectionStyle = link.value == nil ? .none : .default
                loadImage(for: link, into: cell, at: indexPath)
            case .manga(let manga):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = manga.title
                cell.detailTextLabel?.text = manga.legacySummaryText
                loadCover(for: manga, into: cell, at: indexPath)
            case .chapter(let entry):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = entry.manga.title
                cell.detailTextLabel?.text = chapterSubtitle(entry.chapter)
                if entry.chapter.locked {
                    cell.textLabel?.textColor = LegacyPalette.disabledText
                    cell.detailTextLabel?.textColor = LegacyPalette.disabledText
                    cell.accessoryType = .none
                    cell.selectionStyle = .none
                }
                loadCover(for: entry.manga, into: cell, at: indexPath)
            case .filter(let item):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = item.title
                cell.detailTextLabel?.text = "Search with this filter"
            case .listing(_, let title):
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                cell.textLabel?.text = title
                cell.detailTextLabel?.text = "View more"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !rows.isEmpty else { return }
        switch rows[indexPath.row] {
            case .header:
                return
            case .link(let link):
                open(linkValue: link.value)
            case .manga(let manga):
                navigationController?.pushViewController(
                    LegacyMangaDetailViewController(source: source, manga: manga),
                    animated: true
                )
            case .chapter(let entry):
                guard !entry.chapter.locked else {
                    showUnavailableChapterAlert(for: entry.chapter)
                    return
                }
                navigationController?.pushViewController(
                    LegacyReaderFactory.makeReader(source: source, manga: entry.manga, chapter: entry.chapter),
                    animated: true
                )
            case .filter(let item):
                navigationController?.pushViewController(
                    LegacyMangaListViewController(
                        source: source,
                        listing: nil,
                        initialFilters: item.values ?? [],
                        allowsEmptySearch: true,
                        titleOverride: item.title
                    ),
                    animated: true
                )
            case .listing(let listing, _):
                navigationController?.pushViewController(
                    LegacyMangaListViewController(source: source, listing: listing),
                    animated: true
                )
        }
    }

    @objc private func loadHome() {
        guard !isLoading else { return }
        isLoading = true
        message = "Loading home..."
        tableView.reloadData()
        source.runner.getHome { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            self.refreshControl?.endRefreshing()
            switch result {
                case .success(let home):
                    self.rows = self.rows(from: home)
                    self.message = self.rows.isEmpty ? "No home content." : ""
                case .failure(let error):
                    self.rows = []
                    self.message = error.localizedDescription
            }
            self.tableView.reloadData()
        }
    }

    private func rows(from home: AidokuRunnerLegacyHome) -> [Row] {
        var rows = [Row]()
        for component in home.components {
            if component.title != nil || component.subtitle != nil {
                rows.append(.header(title: component.title, subtitle: component.subtitle))
            }
            switch component.value {
                case .imageScroller(let links, _, _, _):
                    rows.append(contentsOf: links.map { .link($0) })
                case .bigScroller(let entries, _):
                    rows.append(contentsOf: entries.map { .manga($0) })
                case .scroller(let entries, let listing):
                    rows.append(contentsOf: entries.map { .link($0) })
                    if let listing = listing {
                        rows.append(.listing(listing, title: "More \(component.title ?? listing.name)"))
                    }
                case .mangaList(_, _, let entries, let listing):
                    rows.append(contentsOf: entries.map { .link($0) })
                    if let listing = listing {
                        rows.append(.listing(listing, title: "More \(component.title ?? listing.name)"))
                    }
                case .mangaChapterList(_, let entries, let listing):
                    rows.append(contentsOf: entries.map { .chapter($0) })
                    if let listing = listing {
                        rows.append(.listing(listing, title: "More \(component.title ?? listing.name)"))
                    }
                case .filters(let items):
                    rows.append(contentsOf: items.map { .filter($0) })
                case .links(let links):
                    rows.append(contentsOf: links.map { .link($0) })
            }
        }
        return rows
    }

    private func open(linkValue: AidokuRunnerLegacyHomeLink.Value?) {
        guard let linkValue = linkValue else { return }
        switch linkValue {
            case .url(let urlString):
                guard let url = URL(string: urlString, relativeTo: source.urls.first)?.absoluteURL else { return }
                navigationController?.pushViewController(
                    LegacySourceWebViewController(url: url, title: source.name),
                    animated: true
                )
            case .listing(let listing):
                navigationController?.pushViewController(
                    LegacyMangaListViewController(source: source, listing: listing),
                    animated: true
                )
            case .manga(let manga):
                navigationController?.pushViewController(
                    LegacyMangaDetailViewController(source: source, manga: manga),
                    animated: true
                )
        }
    }

    private func detailText(for value: AidokuRunnerLegacyHomeLink.Value?) -> String? {
        switch value {
            case .url(let url):
                return url
            case .listing(let listing):
                return listing.name
            case .manga(let manga):
                return manga.legacySummaryText
            case .none:
                return nil
        }
    }

    private func chapterSubtitle(_ chapter: AidokuRunnerLegacyChapter) -> String? {
        let subtitle = chapter.legacyFormattedSubtitle(sourceKey: source.key)
        return [chapter.legacyFormattedTitle, subtitle]
            .compactMap { value in
                guard let value = value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
    }

    private func showUnavailableChapterAlert(for chapter: AidokuRunnerLegacyChapter) {
        let alert = UIAlertController(
            title: "Chapter Unavailable",
            message: "\(chapter.legacyFormattedTitle) is marked unavailable by this source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func loadImage(for link: AidokuRunnerLegacyHomeLink, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        guard let url = imageURL(for: link) else { return }
        LegacyImageLoader.shared.load(url: url, source: source, targetHeight: 130) { image in
            guard
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
    }

    private func loadCover(for manga: AidokuRunnerLegacyManga, into cell: UITableViewCell, at indexPath: IndexPath) {
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: manga.coverURLCandidates(relativeTo: source.urls.first),
            source: source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = self.tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
    }

    private func imageURL(for link: AidokuRunnerLegacyHomeLink) -> URL? {
        if
            let imageUrl = link.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
            !imageUrl.isEmpty
        {
            if let url = URL(string: imageUrl), url.scheme != nil {
                return url
            }
            if let baseURL = source.urls.first {
                return URL(string: imageUrl, relativeTo: baseURL)?.absoluteURL
            }
            return URL(string: imageUrl)
        }

        if case .some(.manga(let manga)) = link.value {
            return manga.coverURL(relativeTo: source.urls.first)
        }
        return nil
    }
}

final class LegacyMangaListViewController: UITableViewController {
    private let source: AidokuRunnerLegacySource
    private let listing: AidokuRunnerLegacyListing?
    private let initialFilters: [AidokuRunnerLegacyFilterValue]
    private let allowsEmptySearch: Bool
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounceTimer: Timer?

    private var entries: [AidokuRunnerLegacyManga] = []
    private var availableFilters: [AidokuRunnerLegacyFilter] = []
    private var enabledFilters: [AidokuRunnerLegacyFilterValue] = []
    private var page = 1
    private var hasNextPage = false
    private var isLoading = false
    private var message = "Enter a search term."

    init(
        source: AidokuRunnerLegacySource,
        listing: AidokuRunnerLegacyListing?,
        initialFilters: [AidokuRunnerLegacyFilterValue] = [],
        allowsEmptySearch: Bool = false,
        titleOverride: String? = nil
    ) {
        self.source = source
        self.listing = listing
        self.initialFilters = initialFilters
        self.allowsEmptySearch = allowsEmptySearch
        super.init(style: .plain)
        title = titleOverride ?? listing?.name ?? "Search"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = 86

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        if listing == nil {
            searchController.searchBar.placeholder = "Search manga"
            searchController.searchBar.delegate = self
            searchController.searchResultsUpdater = self
            searchController.obscuresBackgroundDuringPresentation = false
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
            definesPresentationContext = true
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Filters",
                style: .plain,
                target: self,
                action: #selector(openFilters)
            )
            navigationItem.rightBarButtonItem?.isEnabled = false
            loadSavedFilters()
            if !initialFilters.isEmpty {
                enabledFilters = initialFilters
            }
            loadFilters()
        }

        if listing != nil {
            load(reset: true)
        } else if allowsEmptySearch || !initialFilters.isEmpty {
            load(reset: true)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if entries.isEmpty { return 1 }
        return entries.count + (hasNextPage ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MangaCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "MangaCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText

        if entries.isEmpty {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading..." : message
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.row == entries.count {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading..." : "Load Next Page"
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
        }

        let manga = entries[indexPath.row]
        cell.imageView?.image = LegacyImageLoader.placeholder()
        LegacyImageLoader.shared.loadCover(
            urls: manga.coverURLCandidates(relativeTo: source.urls.first),
            source: source,
            targetHeight: 130
        ) { image in
            guard
                let visibleIndexPath = tableView.indexPath(for: cell),
                visibleIndexPath == indexPath
            else { return }
            cell.imageView?.image = image ?? LegacyImageLoader.placeholder()
            cell.setNeedsLayout()
        }
        cell.textLabel?.text = manga.title
        cell.detailTextLabel?.text = manga.legacySummaryText
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if entries.isEmpty { return }
        if indexPath.row == entries.count {
            load(reset: false)
            return
        }
        navigationController?.pushViewController(
            LegacyMangaDetailViewController(source: source, manga: entries[indexPath.row]),
            animated: true
        )
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !entries.isEmpty, indexPath.row >= max(0, entries.count - 3), hasNextPage {
            load(reset: false)
        }
    }

    @objc private func refresh() {
        load(reset: true)
    }

    private func load(reset: Bool) {
        guard !isLoading else { return }
        let appending = !reset && !entries.isEmpty
        if reset {
            page = 1
            entries = []
            hasNextPage = false
        }
        isLoading = true
        message = "Loading..."
        if appending {
            // Refresh only the footer ("Load Next Page" -> "Loading...") so an
            // in-flight scroll isn't interrupted by a full table reload.
            let footer = IndexPath(row: entries.count, section: 0)
            if hasNextPage, tableView.numberOfRows(inSection: 0) > entries.count {
                tableView.reloadRows(at: [footer], with: .none)
            }
        } else {
            tableView.reloadData()
        }

        let completion: (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            self.refreshControl?.endRefreshing()

            guard case .success(let pageResult) = result else {
                if case .failure(let error) = result {
                    self.message = error.localizedDescription
                }
                self.tableView.reloadData()
                return
            }

            // Incremental append: insert just the new rows instead of reloading
            // the whole table, which would restart every visible cover load.
            if appending, !pageResult.entries.isEmpty {
                let oldCount = self.entries.count
                self.entries.append(contentsOf: pageResult.entries)
                let hadNextPage = self.hasNextPage
                self.hasNextPage = pageResult.hasNextPage
                self.page += 1
                self.message = ""

                let newRows = (oldCount..<self.entries.count).map { IndexPath(row: $0, section: 0) }
                self.tableView.performBatchUpdates({
                    self.tableView.insertRows(at: newRows, with: .none)
                    if hadNextPage, !self.hasNextPage {
                        self.tableView.deleteRows(at: [IndexPath(row: oldCount, section: 0)], with: .none)
                    }
                }, completion: { _ in
                    if self.hasNextPage {
                        let footer = IndexPath(row: self.entries.count, section: 0)
                        if self.tableView.numberOfRows(inSection: 0) > self.entries.count {
                            self.tableView.reloadRows(at: [footer], with: .none)
                        }
                    }
                })
                return
            }

            if reset {
                self.entries = pageResult.entries
            } else {
                self.entries.append(contentsOf: pageResult.entries)
            }
            self.hasNextPage = pageResult.hasNextPage
            self.page += 1
            self.message = self.entries.isEmpty ? "No manga found." : ""
            self.tableView.reloadData()
        }

        if let listing = listing {
            source.runner.getMangaList(listing: listing, page: page, completion: completion)
        } else {
            let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowsEmptySearch || !query.isEmpty || !enabledFilters.isEmpty else {
                isLoading = false
                message = "Enter a search term."
                refreshControl?.endRefreshing()
                tableView.reloadData()
                return
            }
            source.runner.getSearchMangaList(
                query: query.isEmpty ? nil : query,
                page: page,
                filters: enabledFilters,
                completion: completion
            )
        }
    }

    private func loadFilters() {
        availableFilters = source.staticFilters
        updateFilterButton()
        guard source.runner.features.dynamicFilters else { return }
        source.runner.getFilters { [weak self] result in
            guard let self = self else { return }
            if case .success(let filters) = result {
                var seen = Set(self.availableFilters.map { $0.id })
                self.availableFilters.append(contentsOf: filters.filter { seen.insert($0.id).inserted })
            }
            self.updateFilterButton()
        }
    }

    private func loadSavedFilters() {
        guard
            let data = UserDefaults.standard.data(forKey: filterStorageKey),
            let values = try? JSONDecoder().decode([AidokuRunnerLegacyFilterValue].self, from: data)
        else {
            return
        }
        enabledFilters = values
    }

    private func saveFilters() {
        if enabledFilters.isEmpty {
            UserDefaults.standard.removeObject(forKey: filterStorageKey)
        } else if let data = try? JSONEncoder().encode(enabledFilters) {
            UserDefaults.standard.set(data, forKey: filterStorageKey)
        }
    }

    private var filterStorageKey: String {
        return "AidokuLegacy.\(source.key).filters"
    }

    private func updateFilterButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !availableFilters.isEmpty
        let suffix = enabledFilters.isEmpty ? "" : " (\(enabledFilters.count))"
        navigationItem.rightBarButtonItem?.title = "Filters\(suffix)"
    }

    @objc private func openFilters() {
        let filterController = LegacyFilterViewController(
            filters: availableFilters,
            selectedFilters: enabledFilters
        ) { [weak self] values in
            guard let self = self else { return }
            self.enabledFilters = values
            self.saveFilters()
            self.updateFilterButton()
            self.load(reset: true)
        }
        let navigationController = UINavigationController(rootViewController: filterController)
        present(navigationController, animated: true)
    }
}

extension LegacyMangaListViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        load(reset: true)
    }
}

extension LegacyMangaListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard listing == nil else { return }
        searchDebounceTimer?.invalidate()
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard query.count >= 2 || allowsEmptySearch || !enabledFilters.isEmpty else {
            entries = []
            hasNextPage = false
            message = query.isEmpty ? "Enter a search term." : "Keep typing..."
            tableView.reloadData()
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.load(reset: true)
        }
    }
}

final class LegacyFilterViewController: UITableViewController {
    private let filters: [AidokuRunnerLegacyFilter]
    private var selectedFilters: [AidokuRunnerLegacyFilterValue]
    private let onApply: ([AidokuRunnerLegacyFilterValue]) -> Void

    init(
        filters: [AidokuRunnerLegacyFilter],
        selectedFilters: [AidokuRunnerLegacyFilterValue],
        onApply: @escaping ([AidokuRunnerLegacyFilterValue]) -> Void
    ) {
        self.filters = filters
        self.selectedFilters = selectedFilters
        self.onApply = onApply
        super.init(style: .grouped)
        title = "Filters"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = LegacyPalette.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Reset",
            style: .plain,
            target: self,
            action: #selector(resetFilters)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Apply",
            style: .done,
            target: self,
            action: #selector(applyFilters)
        )
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FilterCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "FilterCell")
        let filter = filters[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.textLabel?.text = filter.title ?? filter.id
        cell.detailTextLabel?.text = detailText(for: filter)
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator

        if case .note = filter.value {
            cell.selectionStyle = .none
            cell.accessoryType = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let filter = filters[indexPath.row]
        switch filter.value {
            case .text(let placeholder):
                editText(filter: filter, placeholder: placeholder)
            case .sort(let canAscend, let options, let defaultValue):
                let picker = LegacyFilterOptionPickerViewController(
                    title: filter.title ?? "Sort",
                    options: options.enumerated().map { (label: $0.element, value: String($0.offset)) },
                    selectedValues: Set([String(sortValue(for: filter)?.index ?? defaultValue?.index ?? 0)]),
                    allowsMultiple: false,
                    allowsExclusion: false
                ) { [weak self] included, _ in
                    guard let self = self, let selected = included.first, let index = Int(selected) else { return }
                    let ascending = canAscend ? (self.sortValue(for: filter)?.ascending ?? defaultValue?.ascending ?? false) : false
                    self.replace(.sort(id: filter.id, index: index, ascending: ascending))
                    self.tableView.reloadData()
                }
                navigationController?.pushViewController(picker, animated: true)
            case .check:
                cycleCheck(filter: filter)
            case .select(let select):
                let picker = LegacyFilterOptionPickerViewController(
                    title: filter.title ?? "Select",
                    options: select.options.enumerated().map {
                        let value = select.ids?.indices.contains($0.offset) == true ? select.ids![$0.offset] : $0.element
                        return (label: $0.element, value: value)
                    },
                    selectedValues: Set([selectValue(for: filter) ?? select.defaultValue ?? ""]),
                    allowsMultiple: false,
                    allowsExclusion: false
                ) { [weak self] included, _ in
                    guard let self = self, let value = included.first else { return }
                    self.replace(.select(id: filter.id, value: value))
                    self.tableView.reloadData()
                }
                navigationController?.pushViewController(picker, animated: true)
            case .multiselect(let multiSelect):
                let current = multiselectValue(for: filter)
                let picker = LegacyFilterOptionPickerViewController(
                    title: filter.title ?? "Select",
                    options: multiSelect.options.enumerated().map {
                        let value = multiSelect.ids?.indices.contains($0.offset) == true ? multiSelect.ids![$0.offset] : $0.element
                        return (label: $0.element, value: value)
                    },
                    selectedValues: Set(current?.included ?? multiSelect.defaultIncluded ?? []),
                    excludedValues: Set(current?.excluded ?? multiSelect.defaultExcluded ?? []),
                    allowsMultiple: true,
                    allowsExclusion: multiSelect.canExclude
                ) { [weak self] included, excluded in
                    guard let self = self else { return }
                    self.replace(.multiselect(id: filter.id, included: included, excluded: excluded))
                    self.tableView.reloadData()
                }
                navigationController?.pushViewController(picker, animated: true)
            case .note:
                break
            case .range:
                editRange(filter: filter)
        }
    }

    private func detailText(for filter: AidokuRunnerLegacyFilter) -> String? {
        switch filter.value {
            case .text:
                if case .text(_, let value)? = value(for: filter.id), !value.isEmpty {
                    return value
                }
                return "Any"
            case .sort(_, let options, let defaultValue):
                let value = sortValue(for: filter)
                let index = value?.index ?? defaultValue?.index ?? 0
                let label = options.indices.contains(index) ? options[index] : "Default"
                let ascending = value?.ascending ?? defaultValue?.ascending ?? false
                return ascending ? "\(label), ascending" : label
            case .check:
                if case .check(_, let value)? = value(for: filter.id) {
                    return value < 0 ? "Excluded" : value > 0 ? "Included" : "Any"
                }
                return "Any"
            case .select(let select):
                let value = selectValue(for: filter) ?? select.defaultValue
                guard let selected = value else { return "Default" }
                if let index = select.ids?.firstIndex(of: selected), select.options.indices.contains(index) {
                    return select.options[index]
                }
                return selected
            case .multiselect:
                let current = multiselectValue(for: filter)
                let included = current?.included.count ?? 0
                let excluded = current?.excluded.count ?? 0
                if included == 0 && excluded == 0 { return "Any" }
                return excluded == 0 ? "\(included) selected" : "\(included) selected, \(excluded) excluded"
            case .note(let note):
                return note
            case .range:
                if case .range(_, let from, let to)? = value(for: filter.id) {
                    return "\(from.map { String($0) } ?? "-") - \(to.map { String($0) } ?? "-")"
                }
                return "Any"
        }
    }

    private func editText(filter: AidokuRunnerLegacyFilter, placeholder: String?) {
        let alert = UIAlertController(title: filter.title ?? filter.id, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = placeholder
            if case .text(_, let value)? = self.value(for: filter.id) {
                textField.text = value
            }
        }
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            self.remove(id: filter.id)
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                self.remove(id: filter.id)
            } else {
                self.replace(.text(id: filter.id, value: text))
            }
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func editRange(filter: AidokuRunnerLegacyFilter) {
        let alert = UIAlertController(title: filter.title ?? filter.id, message: nil, preferredStyle: .alert)
        let current = rangeValue(for: filter)
        alert.addTextField { textField in
            textField.placeholder = "From"
            textField.keyboardType = .decimalPad
            textField.text = current?.from.map { String($0) }
        }
        alert.addTextField { textField in
            textField.placeholder = "To"
            textField.keyboardType = .decimalPad
            textField.text = current?.to.map { String($0) }
        }
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            self.remove(id: filter.id)
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in
            let from = alert.textFields?[0].text.flatMap(Float.init)
            let to = alert.textFields?[1].text.flatMap(Float.init)
            if from == nil && to == nil {
                self.remove(id: filter.id)
            } else {
                self.replace(.range(id: filter.id, from: from, to: to))
            }
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func cycleCheck(filter: AidokuRunnerLegacyFilter) {
        guard case .check(_, let canExclude, _) = filter.value else { return }
        let current: Int
        if case .check(_, let value)? = value(for: filter.id) {
            current = value
        } else {
            current = 0
        }
        let next: Int
        if current == 0 {
            next = 1
        } else if current == 1 && canExclude {
            next = -1
        } else {
            next = 0
        }
        if next == 0 {
            remove(id: filter.id)
        } else {
            replace(.check(id: filter.id, value: next))
        }
        tableView.reloadData()
    }

    private func value(for id: String) -> AidokuRunnerLegacyFilterValue? {
        return selectedFilters.first { $0.id == id }
    }

    private func sortValue(for filter: AidokuRunnerLegacyFilter) -> (index: Int, ascending: Bool)? {
        if case .sort(_, let index, let ascending)? = value(for: filter.id) {
            return (index, ascending)
        }
        return nil
    }

    private func selectValue(for filter: AidokuRunnerLegacyFilter) -> String? {
        if case .select(_, let value)? = value(for: filter.id) {
            return value
        }
        return nil
    }

    private func multiselectValue(for filter: AidokuRunnerLegacyFilter) -> (included: [String], excluded: [String])? {
        if case .multiselect(_, let included, let excluded)? = value(for: filter.id) {
            return (included, excluded)
        }
        return nil
    }

    private func rangeValue(for filter: AidokuRunnerLegacyFilter) -> (from: Float?, to: Float?)? {
        if case .range(_, let from, let to)? = value(for: filter.id) {
            return (from, to)
        }
        return nil
    }

    private func replace(_ value: AidokuRunnerLegacyFilterValue) {
        remove(id: value.id)
        selectedFilters.append(value)
    }

    private func remove(id: String) {
        selectedFilters.removeAll { $0.id == id }
    }

    @objc private func resetFilters() {
        selectedFilters = []
        tableView.reloadData()
    }

    @objc private func applyFilters() {
        onApply(selectedFilters)
        dismiss(animated: true)
    }
}

final class LegacyFilterOptionPickerViewController: UITableViewController {
    private let options: [(label: String, value: String)]
    private var selectedValues: Set<String>
    private var excludedValues: Set<String>
    private let allowsMultiple: Bool
    private let allowsExclusion: Bool
    private let onApply: ([String], [String]) -> Void

    init(
        title: String,
        options: [(label: String, value: String)],
        selectedValues: Set<String>,
        excludedValues: Set<String> = [],
        allowsMultiple: Bool,
        allowsExclusion: Bool,
        onApply: @escaping ([String], [String]) -> Void
    ) {
        self.options = options
        self.selectedValues = Set(selectedValues.filter { !$0.isEmpty })
        self.excludedValues = excludedValues
        self.allowsMultiple = allowsMultiple
        self.allowsExclusion = allowsExclusion
        self.onApply = onApply
        super.init(style: .plain)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = LegacyPalette.background
        if allowsMultiple {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(done)
            )
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OptionCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "OptionCell")
        let option = options[indexPath.row]
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.textLabel?.text = option.label
        if selectedValues.contains(option.value) {
            cell.accessoryType = .checkmark
            cell.detailTextLabel?.text = "Included"
        } else if excludedValues.contains(option.value) {
            cell.accessoryType = .detailButton
            cell.detailTextLabel?.text = "Excluded"
        } else {
            cell.accessoryType = .none
            cell.detailTextLabel?.text = nil
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let value = options[indexPath.row].value
        if allowsMultiple {
            cycle(value: value)
            tableView.reloadRows(at: [indexPath], with: .automatic)
        } else {
            onApply([value], [])
            navigationController?.popViewController(animated: true)
        }
    }

    private func cycle(value: String) {
        if selectedValues.contains(value) {
            selectedValues.remove(value)
            if allowsExclusion {
                excludedValues.insert(value)
            }
        } else if excludedValues.contains(value) {
            excludedValues.remove(value)
        } else {
            selectedValues.insert(value)
        }
    }

    @objc private func done() {
        onApply(Array(selectedValues), Array(excludedValues))
        navigationController?.popViewController(animated: true)
    }
}

private final class LegacyReaderPageActionPresenter {
    static func present(
        image: UIImage?,
        pageDescription: String?,
        pageIndex: Int,
        from viewController: UIViewController,
        sourceView: UIView?,
        sourceRect: CGRect? = nil
    ) {
        let alert = UIAlertController(
            title: "Page \(pageIndex + 1)",
            message: pageDescription,
            preferredStyle: .actionSheet
        )
        if let pageDescription = pageDescription {
            alert.addAction(UIAlertAction(title: "Copy Description", style: .default) { _ in
                UIPasteboard.general.string = pageDescription
                viewController.showLegacyReaderAlert(title: "Copied", message: "Page description copied to the clipboard.")
            })
        }
        if let image = image {
            alert.addAction(UIAlertAction(title: "Copy Image", style: .default) { _ in
                UIPasteboard.general.image = image
                viewController.showLegacyReaderAlert(title: "Copied", message: "Page image copied to the clipboard.")
            })
            alert.addAction(UIAlertAction(title: "Download Image", style: .default) { _ in
                UIImageWriteToSavedPhotosAlbum(
                    image,
                    viewController,
                    #selector(UIViewController.legacyReaderImage(_:didFinishSavingWithError:contextInfo:)),
                    nil
                )
            })
            alert.addAction(UIAlertAction(title: "Share Image", style: .default) { _ in
                let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = sourceView ?? viewController.view
                    popover.sourceRect = (sourceView ?? viewController.view).bounds
                }
                viewController.present(activity, animated: true)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            let anchorView: UIView? = sourceView ?? viewController.view
            popover.sourceView = anchorView
            let bounds = anchorView?.bounds ?? .zero
            // Anchoring to the full page-sized cell bounds pushes the popover
            // off-screen on iPad, where it renders as an empty clipped sliver.
            // Prefer the explicit touch-point rect, clamped to the anchor's
            // visible bounds, falling back to the anchor center.
            if let sourceRect = sourceRect, !bounds.intersection(sourceRect).isNull {
                popover.sourceRect = sourceRect
            } else {
                popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            }
        }
        viewController.present(alert, animated: true)
    }
}

private extension UIViewController {
    @objc func legacyReaderImage(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeRawPointer
    ) {
        if let error = error {
            showLegacyReaderAlert(title: "Save Failed", message: error.localizedDescription)
        } else {
            showLegacyReaderAlert(title: "Saved", message: "Page image saved to Photos.")
        }
    }

    func showLegacyReaderAlert(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyChapterDownloadPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let sourceKey: String
    private let mangaKey: String
    private let chapters: [AidokuRunnerLegacyChapter]
    private let onSelect: (AidokuRunnerLegacyChapter) -> Void
    private var filteredChapters: [AidokuRunnerLegacyChapter] = []
    private let searchController = UISearchController(searchResultsController: nil)

    init(
        sourceKey: String,
        mangaKey: String,
        chapters: [AidokuRunnerLegacyChapter],
        onSelect: @escaping (AidokuRunnerLegacyChapter) -> Void
    ) {
        self.sourceKey = sourceKey
        self.mangaKey = mangaKey
        self.chapters = chapters
        self.filteredChapters = chapters
        self.onSelect = onSelect
        super.init(style: .plain)
        title = "Download Chapter"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search chapters"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(1, filteredChapters.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ChapterDownloadCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "ChapterDownloadCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        cell.imageView?.image = nil

        guard filteredChapters.indices.contains(indexPath.row) else {
            cell.textLabel?.text = "No matching chapters."
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let chapter = filteredChapters[indexPath.row]
        let downloaded = LegacyDownloadStore.shared.hasChapter(
            sourceKey: sourceKey,
            mangaKey: mangaKey,
            chapterKey: chapter.key
        )
        var subtitle = chapter.legacyFormattedSubtitle(sourceKey: sourceKey) ?? ""
        if downloaded {
            subtitle = subtitle.isEmpty ? "Downloaded" : "\(subtitle)\nDownloaded"
        }
        cell.textLabel?.text = chapter.legacyFormattedTitle
        cell.detailTextLabel?.text = subtitle.isEmpty ? nil : subtitle
        cell.accessoryType = downloaded ? .checkmark : .none
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard filteredChapters.indices.contains(indexPath.row) else { return }
        let chapter = filteredChapters[indexPath.row]
        navigationController?.popViewController(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [onSelect] in
            onSelect(chapter)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if query.isEmpty {
            filteredChapters = chapters
        } else {
            filteredChapters = chapters.filter { chapter in
                chapter.legacyFormattedTitle.lowercased().contains(query)
                    || (chapter.legacyFormattedSubtitle(sourceKey: sourceKey)?.lowercased().contains(query) ?? false)
                    || (chapter.language?.lowercased().contains(query) ?? false)
                    || chapter.key.lowercased().contains(query)
            }
        }
        tableView.reloadData()
    }
}

// MARK: - Manga detail header (Mihon-style)

/// Monochrome vector glyphs drawn at runtime. iOS 12 has no SF Symbols, so the
/// detail header draws its icons with bezier paths and renders them as template
/// images so `tintColor` controls the color.
enum LegacyDetailGlyph {
    case person
    case brush
    case globe
    case clock
    case heartOutline
    case heartFilled
    case sync
    case chevronDown
    case chevronUp
    case sliders

    func image(size: CGFloat, lineWidth: CGFloat) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setFillColor(UIColor.black.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            let r = CGRect(x: 0, y: 0, width: size, height: size)
                .insetBy(dx: lineWidth + 1.5, dy: lineWidth + 1.5)
            draw(in: r, lineWidth: lineWidth)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func draw(in r: CGRect, lineWidth: CGFloat) {
        switch self {
            case .person:
                let headRadius = r.width * 0.16
                let headCenter = CGPoint(x: r.midX, y: r.minY + headRadius + r.height * 0.04)
                UIBezierPath(ovalIn: CGRect(
                    x: headCenter.x - headRadius,
                    y: headCenter.y - headRadius,
                    width: headRadius * 2,
                    height: headRadius * 2
                )).fill()
                let body = UIBezierPath()
                let bodyWidth = r.width * 0.72
                let bodyCenter = CGPoint(x: r.midX, y: r.maxY)
                body.move(to: CGPoint(x: bodyCenter.x - bodyWidth / 2, y: bodyCenter.y))
                body.addArc(
                    withCenter: bodyCenter,
                    radius: bodyWidth / 2,
                    startAngle: .pi,
                    endAngle: 0,
                    clockwise: true
                )
                body.close()
                body.fill()
            case .brush:
                let tip = CGPoint(x: r.minX + r.width * 0.14, y: r.maxY - r.height * 0.14)
                let top = CGPoint(x: r.maxX - r.width * 0.14, y: r.minY + r.height * 0.14)
                let handle = UIBezierPath()
                handle.lineWidth = lineWidth
                handle.move(to: tip)
                handle.addLine(to: top)
                handle.stroke()
                // Brush ferrule: a short perpendicular stroke near the top end.
                let ferrule = UIBezierPath()
                ferrule.lineWidth = lineWidth
                let dx = (top.x - tip.x) * 0.16
                let dy = (top.y - tip.y) * 0.16
                ferrule.move(to: CGPoint(x: top.x - dx - dy, y: top.y - dy + dx))
                ferrule.addLine(to: CGPoint(x: top.x - dx + dy, y: top.y - dy - dx))
                ferrule.stroke()
            case .globe:
                let circle = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04)
                let ring = UIBezierPath(ovalIn: circle)
                ring.lineWidth = lineWidth
                ring.stroke()
                let meridian = UIBezierPath(ovalIn: CGRect(
                    x: circle.midX - circle.width * 0.18,
                    y: circle.minY,
                    width: circle.width * 0.36,
                    height: circle.height
                ))
                meridian.lineWidth = lineWidth
                meridian.stroke()
                let equator = UIBezierPath()
                equator.lineWidth = lineWidth
                equator.move(to: CGPoint(x: circle.minX, y: circle.midY))
                equator.addLine(to: CGPoint(x: circle.maxX, y: circle.midY))
                equator.stroke()
            case .clock:
                let circle = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04)
                let ring = UIBezierPath(ovalIn: circle)
                ring.lineWidth = lineWidth
                ring.stroke()
                let center = CGPoint(x: circle.midX, y: circle.midY)
                let hands = UIBezierPath()
                hands.lineWidth = lineWidth
                hands.move(to: center)
                hands.addLine(to: CGPoint(x: center.x, y: circle.minY + circle.height * 0.22))
                hands.move(to: center)
                hands.addLine(to: CGPoint(x: circle.maxX - circle.width * 0.26, y: center.y))
                hands.stroke()
            case .heartOutline, .heartFilled:
                let w = r.width
                let h = r.height
                let path = UIBezierPath()
                path.move(to: CGPoint(x: r.midX, y: r.maxY - h * 0.10))
                path.addCurve(
                    to: CGPoint(x: r.minX + w * 0.04, y: r.minY + h * 0.34),
                    controlPoint1: CGPoint(x: r.midX - w * 0.20, y: r.maxY - h * 0.02),
                    controlPoint2: CGPoint(x: r.minX + w * 0.04, y: r.minY + h * 0.62)
                )
                path.addArc(
                    withCenter: CGPoint(x: r.minX + w * 0.27, y: r.minY + h * 0.32),
                    radius: w * 0.23,
                    startAngle: .pi,
                    endAngle: 0,
                    clockwise: true
                )
                path.addArc(
                    withCenter: CGPoint(x: r.maxX - w * 0.27, y: r.minY + h * 0.32),
                    radius: w * 0.23,
                    startAngle: .pi,
                    endAngle: 0,
                    clockwise: true
                )
                path.addCurve(
                    to: CGPoint(x: r.midX, y: r.maxY - h * 0.10),
                    controlPoint1: CGPoint(x: r.maxX - w * 0.04, y: r.minY + h * 0.62),
                    controlPoint2: CGPoint(x: r.midX + w * 0.20, y: r.maxY - h * 0.02)
                )
                path.close()
                if self == .heartFilled {
                    path.fill()
                } else {
                    path.lineWidth = lineWidth
                    path.stroke()
                }
            case .sync:
                let circle = r.insetBy(dx: r.width * 0.08, dy: r.height * 0.08)
                let center = CGPoint(x: circle.midX, y: circle.midY)
                let radius = circle.width / 2
                let top = UIBezierPath(
                    arcCenter: center,
                    radius: radius,
                    startAngle: CGFloat(-0.95 * Double.pi),
                    endAngle: CGFloat(0.05 * Double.pi),
                    clockwise: true
                )
                top.lineWidth = lineWidth
                top.stroke()
                let bottom = UIBezierPath(
                    arcCenter: center,
                    radius: radius,
                    startAngle: CGFloat(0.05 * Double.pi),
                    endAngle: CGFloat(1.05 * Double.pi),
                    clockwise: true
                )
                bottom.lineWidth = lineWidth
                bottom.stroke()
                let arrowSize = radius * 0.5
                let topTip = CGPoint(x: center.x + radius, y: center.y)
                let topArrow = UIBezierPath()
                topArrow.lineWidth = lineWidth
                topArrow.move(to: CGPoint(x: topTip.x - arrowSize, y: topTip.y - arrowSize * 0.2))
                topArrow.addLine(to: topTip)
                topArrow.addLine(to: CGPoint(x: topTip.x - arrowSize * 0.2, y: topTip.y + arrowSize))
                topArrow.stroke()
                let bottomTip = CGPoint(x: center.x - radius, y: center.y)
                let bottomArrow = UIBezierPath()
                bottomArrow.lineWidth = lineWidth
                bottomArrow.move(to: CGPoint(x: bottomTip.x + arrowSize, y: bottomTip.y + arrowSize * 0.2))
                bottomArrow.addLine(to: bottomTip)
                bottomArrow.addLine(to: CGPoint(x: bottomTip.x + arrowSize * 0.2, y: bottomTip.y - arrowSize))
                bottomArrow.stroke()
            case .chevronDown, .chevronUp:
                let m = r.insetBy(dx: r.width * 0.18, dy: r.height * 0.30)
                let path = UIBezierPath()
                path.lineWidth = lineWidth
                if self == .chevronDown {
                    path.move(to: CGPoint(x: m.minX, y: m.minY))
                    path.addLine(to: CGPoint(x: m.midX, y: m.maxY))
                    path.addLine(to: CGPoint(x: m.maxX, y: m.minY))
                } else {
                    path.move(to: CGPoint(x: m.minX, y: m.maxY))
                    path.addLine(to: CGPoint(x: m.midX, y: m.minY))
                    path.addLine(to: CGPoint(x: m.maxX, y: m.maxY))
                }
                path.stroke()
            case .sliders:
                // "Tune" icon: three horizontal tracks each with a filled knob.
                let rows: [CGFloat] = [
                    r.minY + r.height * 0.20,
                    r.midY,
                    r.maxY - r.height * 0.20
                ]
                let knobCenters: [CGFloat] = [
                    r.minX + r.width * 0.66,
                    r.minX + r.width * 0.34,
                    r.minX + r.width * 0.58
                ]
                let knobRadius = r.width * 0.09
                for (index, y) in rows.enumerated() {
                    let track = UIBezierPath()
                    track.lineWidth = lineWidth
                    track.move(to: CGPoint(x: r.minX, y: y))
                    track.addLine(to: CGPoint(x: r.maxX, y: y))
                    track.stroke()
                    let knobX = knobCenters[index]
                    UIBezierPath(ovalIn: CGRect(
                        x: knobX - knobRadius,
                        y: y - knobRadius,
                        width: knobRadius * 2,
                        height: knobRadius * 2
                    )).fill()
                }
        }
    }
}

/// A single vertical icon-over-label action in the detail header action row.
private final class LegacyDetailActionButton: UIControl {
    private let iconView = UIImageView()
    private let label = UILabel()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        addSubview(label)
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        onTap?()
    }

    func configure(glyph: LegacyDetailGlyph, title: String, tint: UIColor, enabled: Bool) {
        iconView.image = glyph.image(size: 26, lineWidth: 1.7)
        iconView.tintColor = tint
        label.text = title
        label.textColor = tint
        isEnabled = enabled
        alpha = enabled ? 1 : 0.4
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize: CGFloat = 26
        iconView.frame = CGRect(x: (bounds.width - iconSize) / 2, y: 4, width: iconSize, height: iconSize)
        label.frame = CGRect(x: 2, y: iconView.frame.maxY + 4, width: bounds.width - 4, height: bounds.height - iconView.frame.maxY - 6)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : (isEnabled ? 1 : 0.4) }
    }
}

/// Mihon-style header view rendered as the content of the detail screen's first
/// row. Uses manual frame layout (no Auto Layout) so the owning table cell can
/// ask for an exact height via `height(forWidth:)` — important for the flowing
/// tag-chip cloud whose height depends on the available width.
final class LegacyMangaDetailHeaderView: UIView {
    var onLibrary: (() -> Void)?
    var onTracking: (() -> Void)?
    var onWebView: (() -> Void)?
    var onToggleDescription: (() -> Void)?
    var onCover: (() -> Void)?

    private let backdropImageView = UIImageView()
    private let backdropBlur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let backdropScrim = CAGradientLayer()
    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let authorIcon = UIImageView()
    private let authorLabel = UILabel()
    private let artistIcon = UIImageView()
    private let artistLabel = UILabel()
    private let sourceIcon = UIImageView()
    private let sourceLabel = UILabel()
    private let libraryButton = LegacyDetailActionButton()
    private let updatedButton = LegacyDetailActionButton()
    private let trackingButton = LegacyDetailActionButton()
    private let webViewButton = LegacyDetailActionButton()
    private let descriptionLabel = UILabel()
    private let chevronView = UIImageView()
    private let descriptionTapButton = UIButton(type: .custom)
    private let coverTapButton = UIButton(type: .custom)
    private var chipViews: [UILabel] = []

    // Cached configuration.
    private var tags: [String] = []
    private var descriptionExpanded = false
    private var hasDescription = false

    private let horizontalInset: CGFloat = 16
    private let coverSize = CGSize(width: 104, height: 156)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = LegacyPalette.background

        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        addSubview(backdropImageView)
        addSubview(backdropBlur)
        backdropScrim.needsDisplayOnBoundsChange = true
        layer.insertSublayer(backdropScrim, above: backdropBlur.layer)

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerRadius = 8
        coverImageView.layer.borderWidth = 1
        coverImageView.layer.borderColor = UIColor(white: 0.5, alpha: 0.3).cgColor
        coverImageView.backgroundColor = LegacyPalette.panel
        addSubview(coverImageView)

        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleLabel.numberOfLines = 4
        titleLabel.textColor = LegacyPalette.primaryText
        addSubview(titleLabel)

        configureMeta(icon: authorIcon, label: authorLabel)
        configureMeta(icon: artistIcon, label: artistLabel)
        configureMeta(icon: sourceIcon, label: sourceLabel)

        addSubview(libraryButton)
        addSubview(updatedButton)
        addSubview(trackingButton)
        addSubview(webViewButton)
        libraryButton.onTap = { [weak self] in self?.onLibrary?() }
        trackingButton.onTap = { [weak self] in self?.onTracking?() }
        webViewButton.onTap = { [weak self] in self?.onWebView?() }
        updatedButton.isUserInteractionEnabled = false

        descriptionLabel.font = .systemFont(ofSize: 14)
        descriptionLabel.textColor = LegacyPalette.secondaryText
        descriptionLabel.numberOfLines = 0
        addSubview(descriptionLabel)

        chevronView.contentMode = .center
        chevronView.tintColor = LegacyPalette.secondaryText
        addSubview(chevronView)

        descriptionTapButton.addTarget(self, action: #selector(toggleDescription), for: .touchUpInside)
        addSubview(descriptionTapButton)

        coverTapButton.addTarget(self, action: #selector(tapCover), for: .touchUpInside)
        addSubview(coverTapButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureMeta(icon: UIImageView, label: UILabel) {
        icon.contentMode = .scaleAspectFit
        icon.tintColor = LegacyPalette.secondaryText
        addSubview(icon)
        label.font = .systemFont(ofSize: 13)
        label.textColor = LegacyPalette.secondaryText
        label.numberOfLines = 1
        addSubview(label)
    }

    @objc private func toggleDescription() {
        onToggleDescription?()
    }

    @objc private func tapCover() {
        onCover?()
    }

    func setCover(_ image: UIImage?) {
        coverImageView.image = image
        backdropImageView.image = image
    }

    struct Config {
        var title: String
        var authors: [String]
        var artists: [String]
        var sourceName: String
        var description: String?
        var descriptionExpanded: Bool
        var tags: [String]
        var inLibrary: Bool
        var updatedText: String?
        var tracking: Bool
        var hasURL: Bool
        var canPickCover: Bool
        var isError: Bool
    }

    func configure(_ config: Config) {
        titleLabel.text = config.title

        let authorText = config.authors.joined(separator: ", ")
        authorLabel.text = authorText
        let showAuthor = !authorText.isEmpty
        authorIcon.isHidden = !showAuthor
        authorLabel.isHidden = !showAuthor
        authorIcon.image = LegacyDetailGlyph.person.image(size: 14, lineWidth: 1.4)

        let artistText = config.artists.joined(separator: ", ")
        // Hide the artist row when it duplicates the author row.
        let showArtist = !artistText.isEmpty && artistText != authorText
        artistLabel.text = artistText
        artistIcon.isHidden = !showArtist
        artistLabel.isHidden = !showArtist
        artistIcon.image = LegacyDetailGlyph.brush.image(size: 14, lineWidth: 1.4)

        sourceLabel.text = config.sourceName
        sourceIcon.image = LegacyDetailGlyph.globe.image(size: 14, lineWidth: 1.4)

        let trimmedDescription = config.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        hasDescription = !(trimmedDescription?.isEmpty ?? true)
        descriptionLabel.text = trimmedDescription
        descriptionLabel.textColor = config.isError ? LegacyPalette.accent : LegacyPalette.secondaryText
        descriptionExpanded = config.descriptionExpanded
        descriptionLabel.numberOfLines = descriptionExpanded ? 0 : 4
        chevronView.image = (descriptionExpanded ? LegacyDetailGlyph.chevronUp : LegacyDetailGlyph.chevronDown)
            .image(size: 18, lineWidth: 1.6)
        descriptionLabel.isHidden = !hasDescription
        chevronView.isHidden = !hasDescription
        descriptionTapButton.isHidden = !hasDescription

        libraryButton.configure(
            glyph: config.inLibrary ? .heartFilled : .heartOutline,
            title: config.inLibrary ? "In library" : "Add to library",
            tint: config.inLibrary ? LegacyPalette.accent : LegacyPalette.primaryText,
            enabled: true
        )
        updatedButton.configure(
            glyph: .clock,
            title: config.updatedText ?? "Unknown",
            tint: LegacyPalette.secondaryText,
            enabled: config.updatedText != nil
        )
        trackingButton.configure(
            glyph: .sync,
            title: "Tracking",
            tint: config.tracking ? LegacyPalette.accent : LegacyPalette.primaryText,
            enabled: true
        )
        webViewButton.configure(
            glyph: .globe,
            title: "WebView",
            tint: LegacyPalette.primaryText,
            enabled: config.hasURL
        )

        coverTapButton.isUserInteractionEnabled = config.canPickCover

        tags = config.tags
        rebuildChips()
        setNeedsLayout()
    }

    private func rebuildChips() {
        while chipViews.count < tags.count {
            let chip = UILabel()
            chip.font = .systemFont(ofSize: 12)
            chip.textAlignment = .center
            chip.textColor = LegacyPalette.secondaryText
            chip.layer.cornerRadius = 13
            chip.layer.borderWidth = 1
            chip.layer.borderColor = UIColor(white: 0.5, alpha: 0.35).cgColor
            chip.clipsToBounds = true
            addSubview(chip)
            chipViews.append(chip)
        }
        for (index, chip) in chipViews.enumerated() {
            if index < tags.count {
                chip.text = tags[index]
                chip.isHidden = false
            } else {
                chip.isHidden = true
            }
        }
    }

    // MARK: - Layout

    func height(forWidth width: CGFloat) -> CGFloat {
        return performLayout(width: width, apply: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = performLayout(width: bounds.width, apply: true)
    }

    private func textHeight(_ text: String?, font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        guard let text = text, !text.isEmpty, width > 0 else { return 0 }
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        var measured = ceil(bounding.height)
        if maxLines > 0 {
            measured = min(measured, ceil(CGFloat(maxLines) * font.lineHeight))
        }
        return measured
    }

    @discardableResult
    private func performLayout(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        let contentWidth = width - horizontalInset * 2

        // Cover + title block.
        let coverX = horizontalInset
        let coverY: CGFloat = 20
        let titleX = coverX + coverSize.width + 14
        let titleWidth = width - titleX - horizontalInset

        let titleHeight = textHeight(titleLabel.text, font: titleLabel.font, width: titleWidth, maxLines: 4)
        var metaY = coverY + titleHeight + 8
        let metaRows: [(UIImageView, UILabel)] = [
            (authorIcon, authorLabel),
            (artistIcon, artistLabel),
            (sourceIcon, sourceLabel)
        ]
        let metaIconSize: CGFloat = 14
        let metaRowHeight: CGFloat = 18
        var metaFrames: [(icon: CGRect, label: CGRect)] = []
        for (icon, _) in metaRows {
            if icon.isHidden {
                metaFrames.append((.zero, .zero))
                continue
            }
            let iconFrame = CGRect(x: titleX, y: metaY + (metaRowHeight - metaIconSize) / 2, width: metaIconSize, height: metaIconSize)
            let labelFrame = CGRect(x: titleX + metaIconSize + 6, y: metaY, width: titleWidth - metaIconSize - 6, height: metaRowHeight)
            metaFrames.append((iconFrame, labelFrame))
            metaY += metaRowHeight + 2
        }

        let titleBlockBottom = metaY
        let topBlockBottom = max(coverY + coverSize.height, titleBlockBottom) + 16

        // Action row.
        let actionRowY = topBlockBottom
        let actionRowHeight: CGFloat = 58
        let actionColumnWidth = contentWidth / 4

        // Description.
        var cursorY = actionRowY + actionRowHeight + 8
        var descriptionFrame = CGRect.zero
        var chevronFrame = CGRect.zero
        var descriptionTapFrame = CGRect.zero
        if hasDescription {
            let maxLines = descriptionExpanded ? 0 : 4
            let descHeight = textHeight(descriptionLabel.text, font: descriptionLabel.font, width: contentWidth, maxLines: maxLines)
            descriptionFrame = CGRect(x: horizontalInset, y: cursorY, width: contentWidth, height: descHeight)
            chevronFrame = CGRect(x: width / 2 - 11, y: descriptionFrame.maxY + 2, width: 22, height: 18)
            descriptionTapFrame = CGRect(x: horizontalInset, y: cursorY, width: contentWidth, height: descHeight + 22)
            cursorY = chevronFrame.maxY + 12
        }

        // Tag chips (flowing rows).
        var chipFrames: [CGRect] = []
        if !tags.isEmpty {
            let chipHeight: CGFloat = 26
            let chipSpacing: CGFloat = 8
            let lineSpacing: CGFloat = 8
            var x = horizontalInset
            var y = cursorY
            let chipFont = UIFont.systemFont(ofSize: 12)
            for tag in tags {
                let textWidth = (tag as NSString).size(withAttributes: [.font: chipFont]).width
                var chipWidth = ceil(textWidth) + 22
                chipWidth = min(chipWidth, contentWidth)
                if x + chipWidth > horizontalInset + contentWidth && x > horizontalInset {
                    x = horizontalInset
                    y += chipHeight + lineSpacing
                }
                chipFrames.append(CGRect(x: x, y: y, width: chipWidth, height: chipHeight))
                x += chipWidth + chipSpacing
            }
            cursorY = y + chipHeight + 12
        }

        let totalHeight = cursorY + 4

        if apply {
            let backdropBottom = topBlockBottom
            backdropImageView.frame = CGRect(x: 0, y: 0, width: width, height: backdropBottom)
            backdropBlur.frame = backdropImageView.frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropScrim.frame = backdropImageView.frame
            let bg = LegacyPalette.background
            backdropScrim.colors = [
                bg.withAlphaComponent(0.25).cgColor,
                bg.withAlphaComponent(0.6).cgColor,
                bg.cgColor
            ]
            backdropScrim.locations = [0, 0.55, 1]
            CATransaction.commit()

            coverImageView.frame = CGRect(x: coverX, y: coverY, width: coverSize.width, height: coverSize.height)
            coverTapButton.frame = coverImageView.frame
            titleLabel.frame = CGRect(x: titleX, y: coverY, width: titleWidth, height: titleHeight)
            for (index, row) in metaRows.enumerated() {
                row.0.frame = metaFrames[index].icon
                row.1.frame = metaFrames[index].label
            }

            let buttons = [libraryButton, updatedButton, trackingButton, webViewButton]
            for (index, button) in buttons.enumerated() {
                button.frame = CGRect(
                    x: horizontalInset + actionColumnWidth * CGFloat(index),
                    y: actionRowY,
                    width: actionColumnWidth,
                    height: actionRowHeight
                )
            }

            descriptionLabel.frame = descriptionFrame
            chevronView.frame = chevronFrame
            descriptionTapButton.frame = descriptionTapFrame

            for (index, chip) in chipViews.enumerated() where index < chipFrames.count {
                chip.frame = chipFrames[index]
            }
        }

        return totalHeight
    }
}

final class LegacyMangaDetailViewController: UITableViewController {
    private enum ReadingAction {
        case resume(LegacyHistoryEntry)
        case start(AidokuRunnerLegacyChapter)
    }

    private struct ChapterGroup {
        let title: String
        let chapters: [AidokuRunnerLegacyChapter]
    }

    private let source: AidokuRunnerLegacySource
    private var manga: AidokuRunnerLegacyManga
    private var isLoading = false
    private var isDownloading = false
    private var errorMessage: String?
    private var readChapterKeys: Set<String> = []
    private lazy var bookmarkButton = UIBarButtonItem(title: "Add", style: .plain, target: self, action: #selector(toggleBookmark))
    private lazy var downloadButton = UIBarButtonItem(title: "Download", style: .plain, target: self, action: #selector(showDownloadOptions))
    private lazy var languageButton = UIBarButtonItem(title: "Language", style: .plain, target: self, action: #selector(showChapterLanguagePicker))
    private lazy var trackerButton = UIBarButtonItem(title: "Track", style: .plain, target: self, action: #selector(showTrackerLinkOptions))

    private var descriptionExpanded = false
    private lazy var headerView = LegacyMangaDetailHeaderView()
    private lazy var headerCell: UITableViewCell = {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = LegacyPalette.background
        cell.contentView.backgroundColor = LegacyPalette.background
        cell.contentView.addSubview(headerView)
        headerView.frame = cell.contentView.bounds
        headerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return cell
    }()

    private var sourceKey: String { source.key }
    private var mangaKey: String { manga.key }

    init(source: AidokuRunnerLegacySource, manga: AidokuRunnerLegacyManga) {
        self.source = source
        self.manga = manga
        super.init(style: .grouped)
        title = manga.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = LegacyPalette.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        navigationItem.rightBarButtonItems = [bookmarkButton, downloadButton, languageButton, trackerButton]
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleDetailLongPress(_:)))
        tableView.addGestureRecognizer(longPress)
        updateBookmarkButton()
        updateLanguageButton()
        updateTrackerButton()
        setupHeaderCallbacks()
        configureHeader()
        refreshReadChapterKeys()
        loadDetails()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Returning from the reader: refresh read/unread state and resume row.
        refreshReadChapterKeys()
        configureHeader()
        tableView.reloadData()
    }

    private func setupHeaderCallbacks() {
        headerView.onLibrary = { [weak self] in
            self?.toggleBookmark()
            self?.configureHeader()
        }
        headerView.onTracking = { [weak self] in
            self?.showTrackerLinkOptions()
        }
        headerView.onWebView = { [weak self] in
            self?.openMangaInWebView()
        }
        headerView.onCover = { [weak self] in
            self?.showAlternateCoverPicker(from: self?.headerView)
        }
        headerView.onToggleDescription = { [weak self] in
            guard let self = self else { return }
            self.descriptionExpanded.toggle()
            self.configureHeader()
            self.tableView.beginUpdates()
            self.tableView.endUpdates()
        }
    }

    private var headerDescription: String? {
        if let errorMessage = errorMessage {
            return errorMessage
        }
        let trimmed = manga.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private var lastUpdatedText: String? {
        let dates = (manga.chapters ?? []).compactMap { $0.dateUploaded }
        guard let newest = dates.max() else { return nil }
        let days = Calendar.current.dateComponents([.day], from: newest, to: Date()).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 30 { return "\(days) days" }
        let months = days / 30
        if months < 12 { return months == 1 ? "1 month" : "\(months) months" }
        let years = months / 12
        return years == 1 ? "1 year" : "\(years) years"
    }

    private func configureHeader() {
        let inLibrary = LegacyLibraryStore.shared.contains(sourceKey: source.key, mangaKey: manga.key)
        let tracking = !LegacyTrackerManager.shared.entries(sourceKey: sourceKey, mangaKey: mangaKey).isEmpty
        headerView.configure(LegacyMangaDetailHeaderView.Config(
            title: manga.title,
            authors: manga.authors ?? [],
            artists: manga.artists ?? [],
            sourceName: source.name,
            description: headerDescription,
            descriptionExpanded: descriptionExpanded,
            tags: LegacyLibraryEntry.normalizedList(manga.tags ?? []),
            inLibrary: inLibrary,
            updatedText: lastUpdatedText,
            tracking: tracking,
            hasURL: manga.url != nil,
            canPickCover: source.runner.features.providesAlternateCovers,
            isError: errorMessage != nil
        ))
        LegacyImageLoader.shared.loadCover(
            urls: currentCoverURLs,
            source: source,
            targetHeight: 320
        ) { [weak self] image in
            self?.headerView.setCover(image ?? LegacyImageLoader.placeholder())
        }
    }

    private func openMangaInWebView() {
        guard let url = manga.url else { return }
        let webView = LegacySourceWebViewController(url: url, title: manga.title)
        navigationController?.pushViewController(webView, animated: true)
    }

    private func refreshReadChapterKeys() {
        readChapterKeys = LegacyHistoryStore.shared.readChapterKeys(sourceKey: source.key, mangaKey: manga.key)
    }

    @objc private func handleDetailLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let location = recognizer.location(in: tableView)
        guard
            let indexPath = tableView.indexPathForRow(at: location),
            indexPath.section == 0
        else { return }
        showMangaActions(from: tableView.cellForRow(at: indexPath))
    }

    private func showMangaActions(from sourceView: UIView?) {
        let alert = UIAlertController(title: manga.title, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak self] _ in
            self?.showDownloadOptions()
        })
        alert.addAction(UIAlertAction(title: LegacyString("migration.title"), style: .default) { [weak self] _ in
            self?.openMigration()
        })
        alert.addAction(UIAlertAction(title: "Share Cover Image", style: .default) { [weak self] _ in
            self?.shareCoverImage(from: sourceView)
        })
        if source.runner.features.providesAlternateCovers {
            alert.addAction(UIAlertAction(title: "Set as Cover", style: .default) { [weak self] _ in
                self?.showAlternateCoverPicker(from: sourceView)
            })
        }
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { [weak self] _ in
            self?.copyMangaInfo()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView ?? view
            popover.sourceRect = (sourceView ?? view).bounds
        }
        present(alert, animated: true)
    }

    private func openMigration() {
        navigationController?.pushViewController(
            LegacyMangaMigrationViewController(source: source, manga: manga),
            animated: true
        )
    }

    private func shareCoverImage(from sourceView: UIView?) {
        LegacyImageLoader.shared.loadCover(
            urls: currentCoverURLs,
            source: source,
            targetHeight: 1024
        ) { [weak self] image in
            guard let self = self else { return }
            guard let image = image else {
                self.showAlert(title: "No Cover", message: "The cover image is not available yet.")
                return
            }
            let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = sourceView ?? self.view
                popover.sourceRect = (sourceView ?? self.view).bounds
            }
            self.present(controller, animated: true)
        }
    }

    private func copyMangaInfo() {
        var text = manga.title
        if let url = manga.url?.absoluteString, !url.isEmpty {
            text += "\n" + url
        }
        UIPasteboard.general.string = text
    }

    private var currentCoverURLs: [URL] {
        return manga.coverURLCandidates(relativeTo: source.urls.first)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2 + max(1, chapterGroups.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return nil
        }
        if section == 1 {
            return readingActions.isEmpty ? nil : "Reading"
        }
        let groups = chapterGroups
        if groups.isEmpty {
            return isLoading ? "Chapters" : "No Chapters"
        }
        if groups.count == 1 {
            let count = groups[0].chapters.count
            return count == 1 ? "1 Chapter" : "\(count) Chapters"
        }
        return groups[section - 2].title
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 0 {
            return headerView.height(forWidth: tableView.bounds.width)
        }
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 {
            return .leastNormalMagnitude
        }
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1
        }
        if section == 1 {
            return readingActions.count
        }
        let groups = chapterGroups
        guard !groups.isEmpty else { return 1 }
        return groups[section - 2].chapters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DetailCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "DetailCell")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.detailTextLabel?.numberOfLines = 3
        cell.imageView?.image = nil

        if indexPath.section == 0 {
            configureHeader()
            return headerCell
        }

        if indexPath.section == 1 {
            let actions = readingActions
            guard actions.indices.contains(indexPath.row) else { return cell }
            switch actions[indexPath.row] {
                case .resume(let entry):
                    cell.textLabel?.text = "Resume Reading"
                    cell.detailTextLabel?.text = resumeSubtitle(for: entry)
                case .start(let chapter):
                    cell.textLabel?.text = "Read from First Chapter"
                    cell.detailTextLabel?.text = chapter.legacyFormattedTitle
            }
            cell.imageView?.image = nil
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }

        let groups = chapterGroups
        guard groups.indices.contains(indexPath.section - 2), !groups[indexPath.section - 2].chapters.isEmpty else {
            cell.imageView?.image = nil
            cell.textLabel?.text = isLoading ? "Loading chapters..." : "No chapters."
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            return cell
        }

        let chapter = groups[indexPath.section - 2].chapters[indexPath.row]
        cell.imageView?.image = nil
        cell.textLabel?.text = chapter.legacyFormattedTitle
        var subtitle = chapter.legacyFormattedSubtitle(sourceKey: source.key) ?? ""
        if LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            subtitle = subtitle.isEmpty ? "Downloaded" : "\(subtitle)\nDownloaded"
        }
        cell.detailTextLabel?.text = subtitle.isEmpty ? nil : subtitle
        if chapter.locked {
            cell.textLabel?.textColor = LegacyPalette.disabledText
            cell.detailTextLabel?.textColor = LegacyPalette.disabledText
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else {
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            if readChapterKeys.contains(chapter.key) {
                // Read to completion: dim, no unread dot.
                cell.textLabel?.textColor = LegacyPalette.disabledText
                cell.detailTextLabel?.textColor = LegacyPalette.disabledText
            } else {
                // Unread: bright title with a leading accent dot (Mihon-style).
                let dot = NSMutableAttributedString(
                    string: "\u{25CF} ",
                    attributes: [.foregroundColor: LegacyPalette.accent]
                )
                dot.append(NSAttributedString(
                    string: chapter.legacyFormattedTitle,
                    attributes: [.foregroundColor: LegacyPalette.primaryText]
                ))
                cell.textLabel?.attributedText = dot
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            // The header view handles its own taps (cover, action buttons, description).
            return
        }
        if indexPath.section == 1 {
            let actions = readingActions
            guard actions.indices.contains(indexPath.row) else { return }
            switch actions[indexPath.row] {
                case .resume(let entry):
                    pushReader(chapter: entry.chapter, initialPageIndex: entry.pageIndex)
                case .start(let chapter):
                    pushReader(chapter: chapter)
            }
            return
        }
        guard
            indexPath.section >= 2,
            chapterGroups.indices.contains(indexPath.section - 2),
            chapterGroups[indexPath.section - 2].chapters.indices.contains(indexPath.row)
        else {
            return
        }
        let chapter = chapterGroups[indexPath.section - 2].chapters[indexPath.row]
        guard !chapter.locked else {
            showUnavailableChapterAlert(for: chapter)
            return
        }
        pushReader(chapter: chapter)
    }

    private func showAlternateCoverPicker(from sourceView: UIView?) {
        guard source.runner.features.providesAlternateCovers else { return }
        source.runner.getAlternateCovers(manga: manga) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard case .success(let covers) = result else {
                    self.showAlert(title: "Covers Unavailable", message: "This source did not return alternate covers.")
                    return
                }
                let coverValues = covers
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .reduce(into: [String]()) { result, cover in
                        if !result.contains(cover) {
                            result.append(cover)
                        }
                    }
                guard !coverValues.isEmpty else {
                    self.showAlert(title: "No Covers", message: "No alternate covers are available for this manga.")
                    return
                }

                let alert = UIAlertController(title: "Select Cover", message: self.manga.title, preferredStyle: .actionSheet)
                for (index, cover) in coverValues.enumerated() {
                    let title = cover == self.manga.cover ? "Current Cover" : "Cover \(index + 1)"
                    alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                        self?.applyAlternateCover(cover)
                    })
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = sourceView ?? self.view
                    popover.sourceRect = (sourceView ?? self.view).bounds
                }
                self.present(alert, animated: true)
            }
        }
    }

    private func applyAlternateCover(_ cover: String) {
        let oldCoverURLs = currentCoverURLs
        manga.cover = cover
        let newCoverURLs = currentCoverURLs
        LegacyImageLoader.shared.removeCachedImages(for: oldCoverURLs + newCoverURLs, source: source)
        LegacyLibraryStore.shared.updateMangaMetadata(manga: manga, source: source)
        LegacyHistoryStore.shared.updateMangaMetadata(manga: manga, source: source)
        LegacyUpdateStore.shared.updateMangaMetadata(manga: manga, source: source)
        tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
    }

    override func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard
            indexPath.section >= 2,
            chapterGroups.indices.contains(indexPath.section - 2),
            chapterGroups[indexPath.section - 2].chapters.indices.contains(indexPath.row)
        else {
            return nil
        }
        let chapter = chapterGroups[indexPath.section - 2].chapters[indexPath.row]
        guard !chapter.locked else { return nil }
        if LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            let remove = UITableViewRowAction(style: .destructive, title: "Remove Download") { [weak self] _, _ in
                guard let self = self else { return }
                LegacyDownloadStore.shared.delete(sourceKey: self.source.key, mangaKey: self.manga.key, chapterKey: chapter.key)
                self.tableView.reloadData()
            }
            return [remove]
        }
        let download = UITableViewRowAction(style: .normal, title: "Download") { [weak self] _, _ in
            self?.download(chapters: [chapter])
        }
        return [download]
    }

    private func loadDetails() {
        isLoading = true
        tableView.reloadData()
        source.runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                    case .success(let updatedManga):
                        self.manga = self.manga.mergedWithUpdate(updatedManga)
                        LegacyLibraryStore.shared.updateMangaMetadata(manga: self.manga, source: self.source)
                        LegacyHistoryStore.shared.updateMangaMetadata(manga: self.manga, source: self.source)
                        LegacyUpdateStore.shared.updateMangaMetadata(manga: self.manga, source: self.source)
                        self.errorMessage = nil
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                }
                self.updateBookmarkButton()
                self.updateLanguageButton()
                self.configureHeader()
                self.tableView.reloadData()
            }
        }
    }

    @objc private func toggleBookmark() {
        if LegacyLibraryStore.shared.contains(sourceKey: source.key, mangaKey: manga.key) {
            LegacyLibraryStore.shared.remove(sourceKey: source.key, mangaKey: manga.key)
        } else {
            LegacyLibraryStore.shared.add(manga: manga, source: source)
        }
        updateBookmarkButton()
    }

    private func updateBookmarkButton() {
        let inLibrary = LegacyLibraryStore.shared.contains(sourceKey: source.key, mangaKey: manga.key)
        bookmarkButton.title = inLibrary ? "Remove" : "Add"
    }

    private func updateLanguageButton() {
        let chapters = manga.chapters ?? []
        let languages = availableChapterLanguages(in: chapters)
        languageButton.isEnabled = languages.count > 1
        if let language = activeChapterLanguage(in: chapters) {
            languageButton.title = language.uppercased()
        } else {
            languageButton.title = "Language"
        }
    }

    // MARK: - Tracking

    private func updateTrackerButton() {
        let linked = !LegacyTrackerManager.shared.entries(sourceKey: sourceKey, mangaKey: mangaKey).isEmpty
        trackerButton.title = linked ? "Tracked" : "Track"
    }

    @objc private func showTrackerLinkOptions() {
        let manager = LegacyTrackerManager.shared
        let loggedIn = manager.loggedInTrackers
        guard !loggedIn.isEmpty else {
            presentDetailAlert(
                title: "No Tracker Connected",
                message: "Connect AniList or MyAnimeList in Settings -> Trackers first."
            )
            return
        }

        let alert = UIAlertController(title: "Tracking", message: manga.title, preferredStyle: .actionSheet)
        for trackerId in loggedIn {
            if let entry = manager.entry(trackerId: trackerId, sourceKey: sourceKey, mangaKey: mangaKey) {
                alert.addAction(UIAlertAction(title: "\(trackerId.displayName): \(entry.status.displayName)", style: .default) { [weak self] _ in
                    self?.presentTrackerStatusOptions(entry: entry)
                })
            } else {
                alert.addAction(UIAlertAction(title: "Link to \(trackerId.displayName)", style: .default) { [weak self] _ in
                    self?.beginLink(trackerId: trackerId)
                })
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = trackerButton
        }
        present(alert, animated: true)
    }

    private func beginLink(trackerId: LegacyTrackerId) {
        let searchVC = LegacyTrackerSearchViewController(
            trackerId: trackerId,
            initialQuery: manga.title
        ) { [weak self] result in
            guard let self = self else { return }
            LegacyTrackerManager.shared.link(
                trackerId: trackerId,
                sourceKey: self.sourceKey,
                mangaKey: self.mangaKey,
                remoteId: result.remoteId
            ) { linkResult in
                DispatchQueue.main.async {
                    self.updateTrackerButton()
                    if case .failure(let error) = linkResult {
                        self.presentDetailAlert(title: "Linked With Warnings", message: error.localizedDescription)
                    }
                }
            }
        }
        navigationController?.pushViewController(searchVC, animated: true)
    }

    private func presentTrackerStatusOptions(entry: LegacyTrackEntry) {
        let alert = UIAlertController(title: "Status", message: nil, preferredStyle: .actionSheet)
        for status in LegacyTrackStatus.allCases {
            let title = status == entry.status ? "\(status.displayName) (Current)" : status.displayName
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                LegacyTrackerManager.shared.updateEntry(entry, status: status, score: nil) { result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result {
                            self?.presentDetailAlert(title: "Update Failed", message: error.localizedDescription)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Set Score... (\(trackerScoreText(entry.score, trackerId: entry.trackerId)))", style: .default) { [weak self] _ in
            self?.presentTrackerScoreEditor(entry: entry)
        })
        if entry.score > 0 {
            alert.addAction(UIAlertAction(title: "Clear Score", style: .default) { [weak self] _ in
                LegacyTrackerManager.shared.updateEntry(entry, status: nil, score: 0) { result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result {
                            self?.presentDetailAlert(title: "Update Failed", message: error.localizedDescription)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Unlink", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            LegacyTrackerManager.shared.unlink(
                trackerId: entry.trackerId,
                sourceKey: self.sourceKey,
                mangaKey: self.mangaKey
            )
            self.updateTrackerButton()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = trackerButton
        }
        present(alert, animated: true)
    }

    private func presentTrackerScoreEditor(entry: LegacyTrackEntry) {
        let maxScore: Float = entry.trackerId == .anilist ? 100 : 10
        let alert = UIAlertController(
            title: "Set \(entry.trackerId.displayName) Score",
            message: "Enter a score from 0 to \(trackerScoreText(maxScore, trackerId: entry.trackerId)).",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.keyboardType = .decimalPad
            textField.placeholder = "0-\(self.trackerScoreText(maxScore, trackerId: entry.trackerId))"
            textField.text = entry.score > 0 ? self.trackerScoreText(entry.score, trackerId: entry.trackerId) : nil
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let raw = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".") ?? ""
            guard let value = Float(raw), value >= 0, value <= maxScore else {
                self.presentDetailAlert(
                    title: "Invalid Score",
                    message: "Enter a score from 0 to \(self.trackerScoreText(maxScore, trackerId: entry.trackerId))."
                )
                return
            }
            LegacyTrackerManager.shared.updateEntry(entry, status: nil, score: value) { result in
                DispatchQueue.main.async {
                    if case .failure(let error) = result {
                        self.presentDetailAlert(title: "Update Failed", message: error.localizedDescription)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func trackerScoreText(_ score: Float, trackerId: LegacyTrackerId) -> String {
        guard score > 0 else { return "Not set" }
        let clamped: Float
        switch trackerId {
            case .anilist:
                clamped = min(max(score, 0), 100)
            case .myanimelist:
                clamped = min(max(score, 0), 10)
        }
        if clamped.rounded() == clamped {
            return String(Int(clamped))
        }
        return String(format: "%.1f", clamped)
    }

    private func presentDetailAlert(title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func showChapterLanguagePicker() {
        let chapters = manga.chapters ?? []
        let languages = availableChapterLanguages(in: chapters)
        guard languages.count > 1 else { return }

        let selectedLanguage = activeChapterLanguage(in: chapters)
        let alert = UIAlertController(title: "Chapter Language", message: manga.title, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "All Languages", style: .default) { [weak self] _ in
            guard let self = self else { return }
            UserDefaults.standard.removeObject(forKey: self.chapterLanguageDefaultsKey)
            self.updateLanguageButton()
            self.tableView.reloadData()
        })
        for language in languages {
            let count = chapters.filter { $0.normalizedLanguage == language && !$0.locked }.count
            let suffix = selectedLanguage == language ? " Selected" : ""
            let title = "\(languageTitle(language)) (\(count))\(suffix)"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                UserDefaults.standard.set(language, forKey: self.chapterLanguageDefaultsKey)
                self.updateLanguageButton()
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = languageButton
        }
        present(alert, animated: true)
    }

    @objc private func showDownloadOptions() {
        let readableChapters = displayChapters.filter { !$0.locked }
        guard !readableChapters.isEmpty else {
            showAlert(title: "No Chapters", message: "No readable chapters are available to download.")
            return
        }
        let alert = UIAlertController(title: "Download", message: manga.title, preferredStyle: .actionSheet)
        if let first = firstReadableChapter {
            alert.addAction(UIAlertAction(title: "Download First Chapter", style: .default) { [weak self] _ in
                self?.download(chapters: [first])
            })
        }
        alert.addAction(UIAlertAction(title: "Download Specific Chapter", style: .default) { [weak self] _ in
            self?.showSpecificChapterDownloadPicker(chapters: readableChapters)
        })
        alert.addAction(UIAlertAction(title: "Download All Chapters", style: .default) { [weak self] _ in
            self?.download(chapters: readableChapters)
        })
        alert.addAction(UIAlertAction(title: "Open Downloads", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(LegacyDownloadsViewController(), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = downloadButton
        }
        present(alert, animated: true)
    }

    private func showSpecificChapterDownloadPicker(chapters: [AidokuRunnerLegacyChapter]) {
        let picker = LegacyChapterDownloadPickerViewController(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapters: chapters
        ) { [weak self] chapter in
            self?.download(chapters: [chapter])
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func download(chapters: [AidokuRunnerLegacyChapter]) {
        guard !isDownloading else { return }
        let pending = chapters.filter {
            !LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: $0.key)
        }
        guard !pending.isEmpty else {
            showAlert(title: "Already Downloaded", message: "Selected chapters are already saved offline.")
            return
        }
        isDownloading = true
        downloadButton.isEnabled = false
        download(chapters: pending, index: 0, completed: 0)
    }

    private func download(chapters: [AidokuRunnerLegacyChapter], index: Int, completed: Int) {
        guard chapters.indices.contains(index) else {
            isDownloading = false
            downloadButton.isEnabled = true
            navigationItem.prompt = nil
            tableView.reloadData()
            showAlert(title: "Download Complete", message: "Saved \(completed) chapter(s) for offline reading.")
            return
        }
        let chapter = chapters[index]
        navigationItem.prompt = "Downloading \(index + 1) of \(chapters.count)..."
        LegacyDownloadManager.shared.download(
            source: source,
            manga: manga,
            chapter: chapter,
            progress: { [weak self] page, total in
                DispatchQueue.main.async {
                    self?.navigationItem.prompt = "Downloading \(index + 1) of \(chapters.count) - Page \(page)/\(total)"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                        case .success:
                            self.download(chapters: chapters, index: index + 1, completed: completed + 1)
                        case .failure(let error):
                            self.isDownloading = false
                            self.downloadButton.isEnabled = true
                            self.navigationItem.prompt = nil
                            self.tableView.reloadData()
                            self.showAlert(title: "Download Failed", message: error.localizedDescription)
                    }
                }
            }
        )
    }

    private var readingActions: [ReadingAction] {
        var actions: [ReadingAction] = []
        if let entry = LegacyHistoryStore.shared.latest(sourceKey: source.key, mangaKey: manga.key) {
            actions.append(.resume(entry))
        }
        if let chapter = firstReadableChapter {
            actions.append(.start(chapter))
        }
        return actions
    }

    private var displayChapters: [AidokuRunnerLegacyChapter] {
        let chapters = manga.chapters ?? []
        guard let language = activeChapterLanguage(in: chapters) else {
            return chapters
        }
        let filtered = chapters.filter { $0.normalizedLanguage == language || $0.normalizedLanguage == nil }
        return filtered.isEmpty ? chapters : filtered
    }

    private var chapterGroups: [ChapterGroup] {
        let chapters = displayChapters
        guard !chapters.isEmpty else { return [] }
        let grouped = Dictionary(grouping: chapters) { chapter -> String in
            return chapter.normalizedLanguage ?? "unknown"
        }
        guard grouped.keys.count > 1 else {
            return [ChapterGroup(title: "Chapters", chapters: chapters)]
        }
        let knownKeys = orderedLanguages(grouped.keys.filter { $0 != "unknown" })
        let orderedKeys = grouped.keys.contains("unknown") ? knownKeys + ["unknown"] : knownKeys
        return orderedKeys.map { key in
            ChapterGroup(title: "Chapters - \(languageTitle(key))", chapters: grouped[key] ?? [])
        }
    }

    private var firstReadableChapter: AidokuRunnerLegacyChapter? {
        let chapters = displayChapters.filter { !$0.locked }
        return chapters.sorted(by: legacyChapterAscending).first
    }

    private func selectedChapterLanguages() -> [String] {
        return (UserDefaults.standard.stringArray(forKey: "\(source.key).languages") ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var chapterLanguageDefaultsKey: String {
        return "\(source.key).\(manga.key).chapterLanguage"
    }

    private func activeChapterLanguage(in chapters: [AidokuRunnerLegacyChapter]) -> String? {
        let languages = availableChapterLanguages(in: chapters)
        guard !languages.isEmpty else { return nil }
        let savedLanguage = UserDefaults.standard.string(forKey: chapterLanguageDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let savedLanguage = savedLanguage, languages.contains(savedLanguage) {
            return savedLanguage
        }
        let selectedLanguages = selectedChapterLanguages()
        if
            selectedLanguages.count == 1,
            let selectedLanguage = selectedLanguages.first,
            languages.contains(selectedLanguage)
        {
            return selectedLanguage
        }
        return languages.count == 1 ? languages[0] : nil
    }

    private func availableChapterLanguages(in chapters: [AidokuRunnerLegacyChapter]) -> [String] {
        var languages: [String] = []
        for chapter in chapters {
            guard let language = chapter.normalizedLanguage else { continue }
            if !languages.contains(language) {
                languages.append(language)
            }
        }
        let selectedLanguages = selectedChapterLanguages()
        if !selectedLanguages.isEmpty {
            let selected = languages.filter { selectedLanguages.contains($0) }
            if !selected.isEmpty {
                languages = selected
            }
        }
        return orderedLanguages(languages)
    }

    private func orderedLanguages(_ languages: [String]) -> [String] {
        let preferredLanguages = preferredChapterLanguages()
        return languages.sorted { lhs, rhs in
            let lhsIndex = preferredLanguages.firstIndex(of: lhs) ?? Int.max
            let rhsIndex = preferredLanguages.firstIndex(of: rhs) ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return languageTitle(lhs).localizedCaseInsensitiveCompare(languageTitle(rhs)) == .orderedAscending
        }
    }

    private func preferredChapterLanguages() -> [String] {
        var values: [String] = []
        for identifier in Locale.preferredLanguages {
            let normalizedIdentifier = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if !values.contains(normalizedIdentifier) {
                values.append(normalizedIdentifier)
            }
            let locale = Locale(identifier: identifier)
            if
                let languageCode = locale.languageCode?.lowercased(),
                !values.contains(languageCode)
            {
                values.append(languageCode)
            }
        }
        for language in selectedChapterLanguages() where !values.contains(language) {
            values.append(language)
        }
        return values
    }

    private func languageTitle(_ language: String) -> String {
        if language == "unknown" {
            return "Unknown Language"
        }
        return Locale.current.localizedString(forIdentifier: language) ?? language.uppercased()
    }

    private func resumeSubtitle(for entry: LegacyHistoryEntry) -> String {
        if entry.pageCount > 0 {
            return "\(entry.chapter.legacyFormattedTitle) - Page \(entry.pageIndex + 1) of \(entry.pageCount)"
        }
        return entry.chapter.legacyFormattedTitle
    }

    private func pushReader(chapter: AidokuRunnerLegacyChapter, initialPageIndex: Int = 0) {
        let reader = LegacyReaderFactory.makeReader(
            source: source,
            manga: manga,
            chapter: chapter,
            initialPageIndex: initialPageIndex
        )
        navigationController?.pushViewController(reader, animated: true)
    }

    private func showUnavailableChapterAlert(for chapter: AidokuRunnerLegacyChapter) {
        let alert = UIAlertController(
            title: "Chapter Unavailable",
            message: "\(chapter.legacyFormattedTitle) is marked unavailable by this source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private extension AidokuRunnerLegacyImageRequest {
    func urlRequest(source: AidokuRunnerLegacySource? = nil, fallbackURL: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        request.applyLegacyImageDefaults(for: url)
        request.applyLegacyRefererIfNeeded(source: source, imageURL: fallbackURL ?? url)
        return request
    }
}

private extension URLRequest {
    mutating func applyLegacyImageDefaults(for url: URL) {
        if value(forHTTPHeaderField: "User-Agent") == nil {
            setValue(aidokuLegacyResolveImageUserAgent(for: url), forHTTPHeaderField: "User-Agent")
        }
        if value(forHTTPHeaderField: "Accept") == nil {
            setValue(aidokuLegacyImageAcceptHeader, forHTTPHeaderField: "Accept")
        }
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.cookies(for: url) ?? [])
        for (key, value) in cookieHeaders {
            if key == "Cookie", let existing = self.value(forHTTPHeaderField: "Cookie"), !existing.isEmpty {
                setValue(value + "; " + existing, forHTTPHeaderField: key)
            } else {
                setValue(value, forHTTPHeaderField: key)
            }
        }
        timeoutInterval = 30
    }

    mutating func applyLegacyRefererIfNeeded(source: AidokuRunnerLegacySource?, imageURL: URL) {
        guard value(forHTTPHeaderField: "Referer") == nil else { return }
        let refererURL = source?.urls.first ?? imageURL
        guard let scheme = refererURL.scheme, let host = refererURL.host else { return }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = refererURL.port
        guard let origin = components.url?.absoluteString else { return }
        setValue(origin.hasSuffix("/") ? origin : origin + "/", forHTTPHeaderField: "Referer")
    }
}

// Visibility widened from `private` to internal so AidokuLegacyTests can assert image-request fallback behavior.
func legacyFallbackImageRequest(url: URL, source: AidokuRunnerLegacySource? = nil) -> URLRequest {
    var request = URLRequest(url: url)
    request.applyLegacyImageDefaults(for: url)
    request.applyLegacyRefererIfNeeded(source: source, imageURL: url)
    if aidokuLegacyIsHitomiImage(url: url, source: source), request.value(forHTTPHeaderField: "Origin") == nil {
        request.setValue("https://hitomi.la", forHTTPHeaderField: "Origin")
    }
    return request
}

func legacyFallbackImageRequests(
    url: URL,
    source: AidokuRunnerLegacySource?,
    excluding primaryRequest: URLRequest? = nil
) -> [URLRequest] {
    var requests: [URLRequest] = []
        let urls = [url]
            + legacyMangaDexCoverFallbackURLs(from: url)
            + legacyHitomiThumbnailFallbackURLs(from: url)
    for candidateURL in urls {
        let request = legacyFallbackImageRequest(url: candidateURL, source: source)
        if let primaryRequest = primaryRequest, legacyImageRequestsMatch(request, primaryRequest) {
            continue
        }
        guard !requests.contains(where: { legacyImageRequestsMatch($0, request) }) else {
            continue
        }
        requests.append(request)
    }
    return requests
}

func legacyImageRequestsMatch(_ lhs: URLRequest, _ rhs: URLRequest) -> Bool {
    return lhs.url == rhs.url
        && lhs.httpMethod == rhs.httpMethod
        && lhs.httpBody == rhs.httpBody
        && lhs.allHTTPHeaderFields == rhs.allHTTPHeaderFields
}

private func aidokuLegacyIsHitomiImage(url: URL, source: AidokuRunnerLegacySource?) -> Bool {
    let sourceText = [source?.key, source?.name]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    if sourceText.contains("hitomi") {
        return true
    }
    let host = url.host?.lowercased() ?? ""
    return host.contains("hitomi.la") || host.contains("gold-usergeneratedcontent.net")
}

func legacyMangaDexCoverFallbackURLs(from url: URL) -> [URL] {
    let host = url.host?.lowercased() ?? ""
    let pathComponents = url.pathComponents
    guard
        host.contains("mangadex.org"),
        let coversIndex = pathComponents.firstIndex(where: { $0.lowercased() == "covers" }),
        pathComponents.indices.contains(coversIndex + 2)
    else {
        return []
    }

    let mangaID = pathComponents[coversIndex + 1]
    let fileName = pathComponents[coversIndex + 2]
    let fileNames = legacyMangaDexCoverFileNameCandidates(from: fileName)
    var urls: [URL] = []
    for host in ["uploads.mangadex.org", "mangadex.org"] {
        for fileName in fileNames {
            guard let candidateURL = URL(string: "https://\(host)/covers/\(mangaID)/\(fileName)") else { continue }
            if candidateURL != url, !urls.contains(candidateURL) {
                urls.append(candidateURL)
            }
        }
    }
    return urls
}

private func legacyMangaDexCoverFileNameCandidates(from fileName: String) -> [String] {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let withoutSizeSuffix = trimmed
        .replacingOccurrences(of: ".512.jpg", with: ".jpg", options: [.caseInsensitive])
        .replacingOccurrences(of: ".256.jpg", with: ".jpg", options: [.caseInsensitive])
    var candidates: [String] = []
    for candidate in [
        trimmed,
        withoutSizeSuffix,
        legacyPath(withoutSizeSuffix, insertingSuffixBeforeExtension: ".512"),
        legacyPath(withoutSizeSuffix, insertingSuffixBeforeExtension: ".256")
    ] where !candidates.contains(candidate) {
        candidates.append(candidate)
    }
    return candidates
}

func legacyHitomiThumbnailFallbackURLs(from url: URL) -> [URL] {
    guard aidokuLegacyIsHitomiImage(url: url, source: nil) else { return [] }
    let path = url.path
    let lowercasedPath = path.lowercased()
    guard lowercasedPath.contains("/avif") || url.pathExtension.lowercased() == "avif" else { return [] }

    let replacements = [
        (from: "/avifbigtn/", to: "/webpbigtn/", pathExtension: "webp"),
        (from: "/avifsmalltn/", to: "/webpsmalltn/", pathExtension: "webp"),
        (from: "/avifbigtn/", to: "/bigtn/", pathExtension: "jpg"),
        (from: "/avifsmalltn/", to: "/smalltn/", pathExtension: "jpg")
    ]

    var paths = [path]
    for replacement in replacements {
        let replacedPath = path.replacingOccurrences(
            of: replacement.from,
            with: replacement.to,
            options: [.caseInsensitive]
        )
        guard replacedPath != path else { continue }
        let pathWithExtension = legacyPath(replacedPath, replacingExtensionWith: replacement.pathExtension)
        if !paths.contains(pathWithExtension) {
            paths.append(pathWithExtension)
        }
    }

    guard let currentHost = url.host?.lowercased() else { return [] }
    let hosts = legacyHitomiThumbnailHosts(for: currentHost)
    var urls: [URL] = []
    for host in hosts {
        for candidatePath in paths {
            guard host != currentHost || candidatePath != path else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = host
            components?.path = candidatePath
            guard let candidateURL = components?.url, !urls.contains(candidateURL) else { continue }
            urls.append(candidateURL)
        }
    }
    return urls
}

private func legacyHitomiThumbnailHosts(for currentHost: String) -> [String] {
    var hosts = [currentHost]
    for host in ["tn.gold-usergeneratedcontent.net", "atn.gold-usergeneratedcontent.net", "tn.hitomi.la"] {
        if !hosts.contains(host) {
            hosts.append(host)
        }
    }
    return hosts
}

private func legacyPath(_ path: String, replacingExtensionWith pathExtension: String) -> String {
    let basePath = (path as NSString).deletingPathExtension
    return basePath + "." + pathExtension
}

private func legacyPath(_ path: String, insertingSuffixBeforeExtension suffix: String) -> String {
    let basePath = (path as NSString).deletingPathExtension
    let pathExtension = (path as NSString).pathExtension
    guard !pathExtension.isEmpty else { return path + suffix }
    return basePath + suffix + "." + pathExtension
}

enum LegacyReaderFactory {
    static func makeReader(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        initialPageIndex: Int = 0
    ) -> UIViewController {
        let mode = LegacyReaderMode.current
        if mode.usesPagedReader {
            return LegacyPagedReaderViewController(
                source: source,
                manga: manga,
                chapter: chapter,
                mode: mode,
                initialPageIndex: initialPageIndex
            )
        }
        return LegacyReaderViewController(
            source: source,
            manga: manga,
            chapter: chapter,
            initialPageIndex: initialPageIndex
        )
    }
}

private final class LegacyReaderViewController: UITableViewController, UIGestureRecognizerDelegate {
    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let chapter: AidokuRunnerLegacyChapter
    private let initialPageIndex: Int
    private var pages: [AidokuRunnerLegacyPage] = []
    private var message = "Loading pages..."
    private var didScrollToInitialPage = false
    private var currentPageIndex: Int?
    private var lastSavedHistoryPageIndex: Int?
    private var lastHistorySaveDate = Date.distantPast
    private var pendingHistorySaveWorkItem: DispatchWorkItem?
    private let overlayView = LegacyReaderOverlayView()
    private let filterOverlayView = LegacyReaderFilterOverlayView()
    private var appliedImageSignature = aidokuLegacyReaderImageProcessingSignature()
    private var appliedSidePaddingPercent = aidokuLegacyReaderWebtoonSidePaddingPercent()
    private var barsHidden = false
    private var didShowTapOverlay = false
    private var appStateObservers: [NSObjectProtocol] = []
    private var didTrimVisibleImagesForBackground = false
    private var temporaryPageDirectories: [URL] = []
    private var didRunDownloadAutomation = false
    private weak var readerTapRecognizer: UITapGestureRecognizer?
    private weak var eInkFlashView: UIView?
    private var lastEInkFlashPageIndex: Int?
    private var fitToScreen: Bool {
        return LegacyReaderMode.current == .verticalFit
    }
    private var readerPageSize: CGSize {
        let insets = tableView.adjustedContentInset
        let height = max(320, tableView.bounds.height - insets.top - insets.bottom)
        let width = max(1, tableView.bounds.width)
        return CGSize(width: width, height: height)
    }

    init(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        initialPageIndex: Int = 0
    ) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
        self.initialPageIndex = initialPageIndex
        super.init(style: .plain)
        title = chapter.legacyFormattedTitle
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in appStateObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        navigationItem.largeTitleDisplayMode = .never
        let pageButton = UIBarButtonItem(
            title: "Page",
            style: .plain,
            target: self,
            action: #selector(showCurrentPageActions)
        )
        let settingsButton = UIBarButtonItem(
            image: LegacyDetailGlyph.sliders.image(size: 22, lineWidth: 1.8),
            style: .plain,
            target: self,
            action: #selector(showReaderSettings)
        )
        if aidokuLegacyChapterWebURL(chapter) != nil {
            navigationItem.rightBarButtonItems = [
                settingsButton,
                pageButton,
                UIBarButtonItem(title: "Web", style: .plain, target: self, action: #selector(openChapterWebPage))
            ]
        } else {
            navigationItem.rightBarButtonItems = [settingsButton, pageButton]
        }
        navigationController?.navigationBar.isTranslucent = false
        tableView.backgroundColor = LegacyReaderBackground.current.color
        tableView.separatorStyle = .none
        tableView.register(LegacyPageImageCell.self, forCellReuseIdentifier: "PageImageCell")
        tableView.register(LegacyReaderTransitionTableCell.self, forCellReuseIdentifier: "ReaderTransition")
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        tableView.addGestureRecognizer(tapRecognizer)
        readerTapRecognizer = tapRecognizer
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handlePageLongPress(_:)))
        longPressRecognizer.delegate = self
        tableView.addGestureRecognizer(longPressRecognizer)
        registerAppStateObservers()
        updateReaderMode()
        loadPages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enforceReaderContainer()
        navigationController?.setNavigationBarHidden(barsHidden, animated: animated)
        updateReaderMode()
        installOverlayIfNeeded()
        applyReaderColorSettings()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installOverlayIfNeeded()
        showTapOverlayIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enforceReaderContainer(relayout: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        trimReaderMemory(keepCurrentPage: false)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tabBarController?.tabBar.isHidden = false
        overlayView.removeFromSuperview()
        filterOverlayView.removeFromSuperview()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override var prefersStatusBarHidden: Bool {
        return barsHidden
    }

    @objc private func showReaderSettings() {
        navigationController?.pushViewController(LegacyReaderSettingsViewController(), animated: true)
    }

    /// Applies live reader color/display settings: page background, color filter
    /// overlay, keep-screen-on, and (when grayscale toggles) a cache flush +
    /// reload so pages re-decode in the new color space.
    private func applyReaderColorSettings() {
        let background = LegacyReaderBackground.current.color
        tableView.backgroundColor = background
        for case let cell as LegacyPageImageCell in tableView.visibleCells {
            cell.applyReaderBackground(background)
        }
        filterOverlayView.applySettings()
        UIApplication.shared.isIdleTimerDisabled = aidokuLegacyReaderKeepScreenOn()

        let signature = aidokuLegacyReaderImageProcessingSignature()
        if signature != appliedImageSignature {
            appliedImageSignature = signature
            LegacyReaderImagePipeline.shared.clear()
            reloadPreservingCurrentPage()
        }

        let sidePadding = aidokuLegacyReaderWebtoonSidePaddingPercent()
        if sidePadding != appliedSidePaddingPercent {
            appliedSidePaddingPercent = sidePadding
            reloadPreservingCurrentPage()
        }
    }

    private func reloadPreservingCurrentPage() {
        let page = currentPageIndex
        tableView.reloadData()
        if let page = page, pages.indices.contains(page) {
            DispatchQueue.main.async {
                self.tableView.scrollToRow(at: IndexPath(row: page, section: 0), at: .top, animated: false)
                self.currentPageIndex = page
                self.updatePageHUD()
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.updateReaderMode()
            self.tableView.reloadData()
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        trimReaderMemory(keepCurrentPage: true)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if fitToScreen {
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if pages.isEmpty { return 1 }
        return pages.count + (showsTransitionPage ? 1 : 0)
    }

    private func isTransitionRow(_ indexPath: IndexPath) -> Bool {
        return showsTransitionPage && !pages.isEmpty && indexPath.row == pages.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if isTransitionRow(indexPath) {
            return readerPageSize.height
        }
        if fitToScreen, isImagePage(at: indexPath) {
            return readerPageSize.height
        }
        return pages.isEmpty ? 80 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if isTransitionRow(indexPath) {
            return readerPageSize.height
        }
        if fitToScreen, isImagePage(at: indexPath) {
            return readerPageSize.height
        }
        return pages.isEmpty ? 80 : 900
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if pages.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReaderMessage")
                ?? UITableViewCell(style: .default, reuseIdentifier: "ReaderMessage")
            cell.backgroundColor = UIColor.black
            cell.textLabel?.textColor = UIColor.white
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.text = message
            cell.selectionStyle = .none
            return cell
        }

        if isTransitionRow(indexPath) {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReaderTransition", for: indexPath) as! LegacyReaderTransitionTableCell
            configureTransitionView(cell.transitionView)
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "PageImageCell", for: indexPath) as! LegacyPageImageCell
        cell.onHeightChange = { [weak tableView] in
            tableView?.beginUpdates()
            tableView?.endUpdates()
        }
        cell.configure(
            page: pages[indexPath.row],
            source: source,
            availableSize: readerPageSize,
            fitsViewport: fitToScreen
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let pageCell = cell as? LegacyPageImageCell {
            readerTapRecognizer?.require(toFail: pageCell.zoomDoubleTapRecognizer)
        }
        if isTransitionRow(indexPath) {
            // Keep history/HUD anchored to the last page while the end screen shows.
            if let lastPage = pages.indices.last {
                currentPageIndex = lastPage
                recordHistory(pageIndex: lastPage, force: false)
                updatePageHUD()
            }
            return
        }
        if !pages.isEmpty, indexPath.row < pages.count {
            currentPageIndex = indexPath.row
            recordHistory(pageIndex: indexPath.row, force: false)
            updatePageHUD()
            if fitToScreen {
                flashReaderIfNeeded()
            }
        }

        preloadPages(around: indexPath.row, includeCurrent: false)
    }

    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let pageCell = cell as? LegacyPageImageCell else { return }
        let loadID = pageCell.currentLoadID
        DispatchQueue.main.asyncAfter(deadline: .now() + aidokuLegacyReaderRetainedPageDelay()) { [weak tableView, weak pageCell] in
            guard let tableView = tableView, let pageCell = pageCell else { return }
            guard tableView.indexPath(for: pageCell) == nil else { return }
            pageCell.releaseDecodedImage(ifLoadID: loadID)
        }
    }

    private func loadPages() {
        if let downloadedPages = LegacyDownloadStore.shared.pages(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            setPages(downloadedPages)
            message = downloadedPages.isEmpty ? "No downloaded pages." : ""
            tableView.reloadData()
            scrollToInitialPageIfNeeded()
            updatePageHUD()
            return
        }
        guard !chapter.locked else {
            pages = []
            message = "\(chapter.legacyFormattedTitle) is unavailable from this source."
            tableView.reloadData()
            return
        }
        source.runner.getPageList(manga: manga, chapter: chapter) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                    case .success(let pages):
                        LegacyZipPageResolver.shared.resolve(pages, source: self.source) { [weak self] resolved in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                self.setPages(resolved)
                                self.message = resolved.isEmpty ? "No pages." : ""
                                self.tableView.reloadData()
                                self.scrollToInitialPageIfNeeded()
                                self.updatePageHUD()
                            }
                        }
                    case .failure(let error):
                        self.message = self.readerMessage(for: error)
                        self.tableView.reloadData()
                        self.scrollToInitialPageIfNeeded()
                        self.updatePageHUD()
                }
            }
        }
    }

    private func updateReaderMode() {
        tableView.isPagingEnabled = fitToScreen
        tableView.decelerationRate = fitToScreen ? .fast : .normal
    }

    private func setPages(_ newPages: [AidokuRunnerLegacyPage]) {
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
        temporaryPageDirectories = []
        let prepared = aidokuLegacyPreparePagesForLowMemory(newPages)
        pages = prepared.pages
        temporaryPageDirectories = prepared.temporaryDirectories
        let warmupPageIndex = pages.indices.contains(initialPageIndex) ? initialPageIndex : 0
        preloadPages(around: warmupPageIndex, includeCurrent: true)
    }

    private func preloadPages(around pageIndex: Int, includeCurrent: Bool) {
        let preloadCount = aidokuLegacyReaderPrefetchCount()
        guard preloadCount > 0 || includeCurrent else { return }
        var candidateIndexes = includeCurrent ? [pageIndex] : []
        if preloadCount > 0 {
            candidateIndexes += (1...preloadCount).flatMap { offset in
                [pageIndex + offset, pageIndex - offset]
            }
        }
        for candidateIndex in candidateIndexes where pages.indices.contains(candidateIndex) {
            guard case .url(let url, let context) = pages[candidateIndex].content else { continue }
            LegacyReaderImagePipeline.shared.preload(url: url, context: context, source: source)
        }
    }

    @objc private func toggleBars() {
        barsHidden.toggle()
        navigationController?.setNavigationBarHidden(barsHidden, animated: true)
        overlayView.setControlsHidden(barsHidden, animated: true)
        enforceReaderContainer()
        UIView.animate(withDuration: 0.2, animations: {
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            self.updateReaderMode()
            if self.fitToScreen {
                self.tableView.reloadData()
            }
        })
    }

    @objc private func handleReaderTap(_ recognizer: UITapGestureRecognizer) {
        if isShowingTransitionPage {
            // Tapping anywhere on the end screen advances; the invisible button
            // alone is too small a target to rely on.
            if nextChapter != nil {
                advanceToNextChapter()
            } else {
                toggleBars()
            }
            return
        }
        let location = recognizer.location(in: view)
        let fraction = location.x / max(view.bounds.width, 1)
        switch aidokuLegacyReaderTapAction(xFraction: fraction, nextOnLeft: false) {
            case .previous:
                movePage(delta: -1)
            case .next:
                movePage(delta: 1)
            case .menu:
                toggleBars()
        }
    }

    @objc private func handlePageLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !pages.isEmpty else { return }
        let location = recognizer.location(in: tableView)
        guard
            let indexPath = tableView.indexPathForRow(at: location),
            pages.indices.contains(indexPath.row)
        else { return }
        let point = recognizer.location(in: view)
        showPageActions(
            pageIndex: indexPath.row,
            sourceView: view,
            sourceRect: CGRect(origin: point, size: CGSize(width: 1, height: 1))
        )
    }

    @objc private func showCurrentPageActions() {
        guard !pages.isEmpty else { return }
        let pageIndex = currentPageIndex ?? tableView.indexPathsForVisibleRows?.first?.row ?? initialPageIndex
        guard pages.indices.contains(pageIndex) else { return }
        showPageActions(pageIndex: pageIndex, sourceView: view, sourceRect: topBarAnchorRect)
    }

    private var topBarAnchorRect: CGRect {
        return CGRect(x: view.bounds.maxX - 40, y: max(8, view.safeAreaInsets.top), width: 1, height: 1)
    }

    @objc private func openChapterWebPage() {
        guard let url = aidokuLegacyChapterWebURL(chapter) else { return }
        aidokuLegacyOpenWebPage(url: url, title: chapter.legacyFormattedTitle, from: self)
    }

    private func showPageActions(pageIndex: Int, sourceView: UIView?, sourceRect: CGRect? = nil) {
        guard pages.indices.contains(pageIndex) else { return }
        let visibleImage = (tableView.cellForRow(at: IndexPath(row: pageIndex, section: 0)) as? LegacyPageImageCell)?.currentImage
        resolvePageActionImage(page: pages[pageIndex], visibleImage: visibleImage) { [weak self] image in
            guard let self = self else { return }
            self.resolvePageDescription(pageIndex: pageIndex) { [weak self] pageDescription in
                guard let self = self else { return }
                guard image != nil || pageDescription != nil else {
                    self.showLegacyReaderAlert(title: "No Image", message: "This page image is not available yet.")
                    return
                }
                LegacyReaderPageActionPresenter.present(
                    image: image,
                    pageDescription: pageDescription,
                    pageIndex: pageIndex,
                    from: self,
                    sourceView: sourceView ?? self.view,
                    sourceRect: sourceRect
                )
            }
        }
    }

    private func resolvePageDescription(
        pageIndex: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard pages.indices.contains(pageIndex) else {
            completion(nil)
            return
        }
        aidokuLegacyResolvePageDescription(for: pages[pageIndex], runner: source.runner) { [weak self] description in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let description = description, self.pages.indices.contains(pageIndex) {
                    self.pages[pageIndex].description = description
                    self.pages[pageIndex].hasDescription = true
                }
                completion(description)
            }
        }
    }

    private func resolvePageActionImage(
        page: AidokuRunnerLegacyPage,
        visibleImage: UIImage?,
        completion: @escaping (UIImage?) -> Void
    ) {
        if let visibleImage = visibleImage {
            completion(visibleImage)
            return
        }
        switch page.content {
            case .url(let url, let context):
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source, completion: completion)
            case .image(let data):
                aidokuLegacyImageDecodeQueue.async {
                    let image = autoreleasepool {
                        LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: aidokuLegacyReaderMaxPixelHeight())
                            .map(aidokuLegacyPrepareReaderImageForDisplay)
                    }
                    DispatchQueue.main.async {
                        completion(image)
                    }
                }
            case .text(_), .zipFile(_, _):
                completion(nil)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return shouldHandleReaderTap(from: touch)
    }

    private func shouldHandleReaderTap(from touch: UITouch) -> Bool {
        var view = touch.view
        while let currentView = view {
            if currentView is UIControl {
                // Let the end-screen "next chapter" button handle its own tap.
                return false
            }
            if let zoomableView = currentView as? LegacyZoomableImageView {
                return !zoomableView.isZoomed
            }
            view = currentView.superview
        }
        return true
    }

    private func movePage(delta: Int) {
        guard !pages.isEmpty else { return }
        let current = currentPageIndex ?? tableView.indexPathsForVisibleRows?.first?.row ?? 0
        let next = min(max(current + delta, 0), pages.count - 1)
        guard next != current else {
            overlayView.showGuide(modeTitle: LegacyReaderMode.current.title)
            return
        }
        tableView.scrollToRow(at: IndexPath(row: next, section: 0), at: .top, animated: aidokuLegacyReaderAnimatePageTransitions())
        currentPageIndex = next
        recordHistory(pageIndex: next, force: false)
        updatePageHUD()
        if fitToScreen {
            flashReaderIfNeeded()
        }
    }

    private func jumpToPage(_ pageIndex: Int, animated: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        tableView.scrollToRow(at: IndexPath(row: pageIndex, section: 0), at: .top, animated: animated)
        currentPageIndex = pageIndex
        preloadPages(around: pageIndex, includeCurrent: true)
        recordHistory(pageIndex: pageIndex, force: true)
        updatePageHUD()
        if fitToScreen {
            flashReaderIfNeeded()
        }
    }

    private func installOverlayIfNeeded() {
        if let hostView = navigationController?.view ?? view {
            aidokuLegacyInstallReaderFilterOverlay(
                filterOverlayView,
                host: hostView,
                navigationBar: navigationController?.navigationBar
            )
        }
        guard overlayView.superview == nil else { return }
        guard let hostView = navigationController?.view ?? view else { return }
        overlayView.onPageSelected = { [weak self] pageIndex in
            self?.jumpToPage(pageIndex, animated: false)
        }
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
        overlayView.setControlsHidden(barsHidden, animated: false)
        updatePageHUD()
    }

    private func showTapOverlayIfNeeded() {
        guard aidokuLegacyReaderShowsTapZones(), LegacyReaderNavLayout.current != .disabled, !didShowTapOverlay else { return }
        didShowTapOverlay = true
        overlayView.showGuide(modeTitle: LegacyReaderMode.current.title)
    }

    private func updatePageHUD() {
        overlayView.updatePage(index: currentPageIndex, count: pages.count)
    }

    private func flashReaderIfNeeded() {
        guard aidokuLegacyReaderEInkFlash(), view.window != nil else { return }
        if let pageIndex = currentPageIndex {
            guard lastEInkFlashPageIndex != pageIndex else { return }
            lastEInkFlashPageIndex = pageIndex
        }
        let flashView: UIView
        if let existing = eInkFlashView {
            flashView = existing
        } else {
            flashView = UIView(frame: view.bounds)
            flashView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            flashView.isUserInteractionEnabled = false
            flashView.alpha = 0
            view.addSubview(flashView)
            eInkFlashView = flashView
        }
        flashView.backgroundColor = LegacyReaderBackground.current == .white ? UIColor.black : UIColor.white
        view.bringSubviewToFront(flashView)
        flashView.alpha = 0.85
        UIView.animate(withDuration: 0.12, delay: 0.03, options: [.allowUserInteraction], animations: {
            flashView.alpha = 0
        })
    }

    private func registerAppStateObservers() {
        let center = NotificationCenter.default
        appStateObservers.append(
            center.addObserver(forName: .legacyReaderColorSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.applyReaderColorSettings()
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyMemoryTrimRequested, object: nil, queue: .main) { [weak self] _ in
                self?.trimReaderMemory(keepCurrentPage: true)
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppWillEnterForeground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppWillEnterForeground()
            }
        )
    }

    private func handleAppDidEnterBackground() {
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        didTrimVisibleImagesForBackground = true
        trimReaderMemory(keepCurrentPage: false)
    }

    private func handleAppWillEnterForeground() {
        guard didTrimVisibleImagesForBackground else { return }
        didTrimVisibleImagesForBackground = false
        let pageIndex = currentPageIndex
        tableView.reloadData()
        guard let pageIndex = pageIndex, pages.indices.contains(pageIndex) else { return }
        DispatchQueue.main.async {
            self.tableView.scrollToRow(at: IndexPath(row: pageIndex, section: 0), at: .top, animated: false)
            self.currentPageIndex = pageIndex
            self.updatePageHUD()
        }
    }

    private func trimReaderMemory(keepCurrentPage: Bool) {
        let current = keepCurrentPage ? currentPageIndex : nil
        for cell in tableView.visibleCells {
            guard let pageCell = cell as? LegacyPageImageCell else { continue }
            let indexPath = tableView.indexPath(for: cell)
            if indexPath?.row != current {
                pageCell.releaseDecodedImage()
            }
        }
        aidokuLegacyTrimVolatileCaches()
    }

    private func enforceReaderContainer(relayout: Bool = true) {
        tabBarController?.tabBar.isHidden = true
        guard relayout else { return }
        tabBarController?.view.setNeedsLayout()
        tabBarController?.view.layoutIfNeeded()
    }

    private func isImagePage(at indexPath: IndexPath) -> Bool {
        guard !pages.isEmpty, pages.indices.contains(indexPath.row) else { return false }
        switch pages[indexPath.row].content {
            case .url(_, _), .image(_):
                return true
            case .text(_), .zipFile(_, _):
                return false
        }
    }

    private func readerMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("missing chapter data") {
            return "This chapter is unavailable from the source."
        }
        return message
    }

    private func scrollToInitialPageIfNeeded() {
        guard !didScrollToInitialPage, pages.indices.contains(initialPageIndex) else { return }
        didScrollToInitialPage = true
        DispatchQueue.main.async {
            self.tableView.scrollToRow(
                at: IndexPath(row: self.initialPageIndex, section: 0),
                at: .top,
                animated: false
            )
            self.currentPageIndex = self.initialPageIndex
            self.updatePageHUD()
        }
    }

    private var showsTransitionPage: Bool {
        return !pages.isEmpty
    }

    private var nextChapter: AidokuRunnerLegacyChapter? {
        return legacyReaderNextChapter(after: chapter, in: manga.chapters)
    }

    // True when the end-screen row is the one centered on screen.
    private var isShowingTransitionPage: Bool {
        guard showsTransitionPage else { return false }
        let transitionRow = pages.count
        let centerY = tableView.contentOffset.y + tableView.bounds.height / 2
        let point = CGPoint(x: tableView.bounds.midX, y: centerY)
        return tableView.indexPathForRow(at: point)?.row == transitionRow
    }

    private func configureTransitionView(_ transitionView: LegacyReaderTransitionView) {
        let next = nextChapter
        transitionView.configure(
            finishedTitle: chapter.legacyFormattedTitle,
            finishedUploader: legacyReaderUploaderText(chapter),
            nextTitle: next?.legacyFormattedTitle,
            nextUploader: next.flatMap(legacyReaderUploaderText)
        )
        transitionView.onTapNext = { [weak self] in
            self?.advanceToNextChapter()
        }
    }

    private var previousChapter: AidokuRunnerLegacyChapter? {
        return legacyReaderPreviousChapter(before: chapter, in: manga.chapters)
    }

    private func advanceToNextChapter() {
        guard let next = nextChapter else { return }
        openChapter(next)
    }

    private func goToPreviousChapter() {
        guard let previous = previousChapter else { return }
        openChapter(previous)
    }

    private func openChapter(_ target: AidokuRunnerLegacyChapter) {
        guard let nav = navigationController else { return }
        let reader = LegacyReaderFactory.makeReader(source: source, manga: manga, chapter: target)
        // Replace this reader in the stack so back returns to the manga, not a
        // pile of finished chapters.
        if nav.viewControllers.last === self {
            var stack = nav.viewControllers
            stack[stack.count - 1] = reader
            nav.setViewControllers(stack, animated: true)
        } else {
            nav.pushViewController(reader, animated: true)
        }
    }

    // -1 to load the previous chapter, +1 for the next, set while the user drags
    // past a vertical edge and acted on when the drag ends.
    private var pendingChapterChange = 0

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isTracking else { return }
        let threshold: CGFloat = 90
        let inset = scrollView.adjustedContentInset
        let topLimit = -inset.top
        let bottomLimit = max(topLimit, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        if scrollView.contentOffset.y < topLimit - threshold {
            pendingChapterChange = -1
        } else if scrollView.contentOffset.y > bottomLimit + threshold {
            pendingChapterChange = 1
        } else {
            pendingChapterChange = 0
        }
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let change = pendingChapterChange
        pendingChapterChange = 0
        if change > 0 {
            advanceToNextChapter()
        } else if change < 0 {
            goToPreviousChapter()
        }
    }

    private func recordHistory(pageIndex: Int, force: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        let now = Date()
        if force {
            pendingHistorySaveWorkItem?.cancel()
            pendingHistorySaveWorkItem = nil
        } else {
            if lastSavedHistoryPageIndex == pageIndex {
                return
            }
            let saveDelay = 2 - now.timeIntervalSince(lastHistorySaveDate)
            if saveDelay > 0 {
                pendingHistorySaveWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard self?.currentPageIndex == pageIndex else { return }
                    self?.recordHistory(pageIndex: pageIndex, force: true)
                }
                pendingHistorySaveWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: workItem)
                return
            }
        }
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        // Incognito mode: skip all persistence (history, stats, resume session,
        // tracker sync) but keep throttle bookkeeping so we do not re-schedule.
        if aidokuLegacyIncognitoEnabled() {
            lastSavedHistoryPageIndex = pageIndex
            lastHistorySaveDate = now
            return
        }
        LegacyHistoryStore.shared.update(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        // Push read progress to a linked tracker. No-op when not logged in,
        // not linked, or the chapter is not ahead of stored progress.
        LegacyTrackerManager.shared.syncProgress(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapterNumber: chapter.chapterNumber ?? 0
        )
        LegacyReaderSessionStore.shared.save(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        LegacyReadingStatsStore.shared.recordChapterRead(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapterKey: chapter.key
        )
        runDownloadAutomationIfFinished(pageIndex: pageIndex)
        lastSavedHistoryPageIndex = pageIndex
        lastHistorySaveDate = now
    }

    private func runDownloadAutomationIfFinished(pageIndex: Int) {
        guard !didRunDownloadAutomation, pageIndex >= pages.count - 1 else { return }
        didRunDownloadAutomation = true
        LegacyDownloadAutomation.shared.chapterDidComplete(
            source: source,
            manga: manga,
            chapter: chapter,
            nextUnreadChapter: legacyReaderNextUnreadChapter(
                after: chapter,
                in: manga.chapters,
                sourceKey: source.key,
                mangaKey: manga.key
            )
        )
    }
}

private final class LegacyPagedReaderViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private let source: AidokuRunnerLegacySource
    private let manga: AidokuRunnerLegacyManga
    private let chapter: AidokuRunnerLegacyChapter
    private let mode: LegacyReaderMode
    private let initialPageIndex: Int
    private var collectionView: UICollectionView!
    private var pages: [AidokuRunnerLegacyPage] = []
    private var message = "Loading pages..."
    private var didScrollToInitialPage = false
    private var currentPageIndex: Int?
    private var lastSavedHistoryPageIndex: Int?
    private var lastHistorySaveDate = Date.distantPast
    private var pendingHistorySaveWorkItem: DispatchWorkItem?
    private let overlayView = LegacyReaderOverlayView()
    private let filterOverlayView = LegacyReaderFilterOverlayView()
    private var appliedImageSignature = aidokuLegacyReaderImageProcessingSignature()
    /// Each entry is one screen: a single page index, or two page indices
    /// (a double-page spread). Rebuilt from `pages` whenever the double-page
    /// setting or orientation changes.
    private var spreads: [[Int]] = []
    private var appliedDoublePage = false
    private var isolatedPageIndexes = Set<Int>()
    private var knownWidePageIndexes = Set<Int>()
    private var barsHidden = false
    private var didShowTapOverlay = false
    private var appStateObservers: [NSObjectProtocol] = []
    private var didTrimVisibleImagesForBackground = false
    private var temporaryPageDirectories: [URL] = []
    private var didRunDownloadAutomation = false
    private weak var readerTapRecognizer: UITapGestureRecognizer?
    private weak var eInkFlashView: UIView?
    private var lastEInkFlashPageIndex: Int?

    init(
        source: AidokuRunnerLegacySource,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        mode: LegacyReaderMode,
        initialPageIndex: Int = 0
    ) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
        self.mode = mode
        self.initialPageIndex = initialPageIndex
        super.init(nibName: nil, bundle: nil)
        title = chapter.legacyFormattedTitle
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in appStateObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        navigationItem.largeTitleDisplayMode = .never
        let pageButton = UIBarButtonItem(
            title: "Page",
            style: .plain,
            target: self,
            action: #selector(showCurrentPageActions)
        )
        let settingsButton = UIBarButtonItem(
            image: LegacyDetailGlyph.sliders.image(size: 22, lineWidth: 1.8),
            style: .plain,
            target: self,
            action: #selector(showReaderSettings)
        )
        if aidokuLegacyChapterWebURL(chapter) != nil {
            navigationItem.rightBarButtonItems = [
                settingsButton,
                pageButton,
                UIBarButtonItem(title: "Web", style: .plain, target: self, action: #selector(openChapterWebPage))
            ]
        } else {
            navigationItem.rightBarButtonItems = [settingsButton, pageButton]
        }
        navigationController?.navigationBar.isTranslucent = false
        view.backgroundColor = LegacyReaderBackground.current.color

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = LegacyReaderBackground.current.color
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.alwaysBounceVertical = false
        if aidokuLegacyIsLowMemoryMode() {
            collectionView.isPrefetchingEnabled = false
        }
        collectionView.register(LegacyPagedImageCell.self, forCellWithReuseIdentifier: "PagedImageCell")
        collectionView.register(LegacyPagedMessageCell.self, forCellWithReuseIdentifier: "PagedMessageCell")
        collectionView.register(LegacyPagedTransitionCell.self, forCellWithReuseIdentifier: "PagedTransitionCell")
        collectionView.register(LegacyPagedSpreadCell.self, forCellWithReuseIdentifier: "PagedSpreadCell")
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        collectionView.addGestureRecognizer(tapRecognizer)
        readerTapRecognizer = tapRecognizer
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handlePageLongPress(_:)))
        longPressRecognizer.delegate = self
        collectionView.addGestureRecognizer(longPressRecognizer)

        registerAppStateObservers()
        loadPages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enforceReaderContainer()
        navigationController?.setNavigationBarHidden(barsHidden, animated: animated)
        installOverlayIfNeeded()
        applyReaderColorSettings()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installOverlayIfNeeded()
        showTapOverlayIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enforceReaderContainer(relayout: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        trimReaderMemory(keepCurrentPage: false)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tabBarController?.tabBar.isHidden = false
        overlayView.removeFromSuperview()
        filterOverlayView.removeFromSuperview()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override var prefersStatusBarHidden: Bool {
        return barsHidden
    }

    @objc private func showReaderSettings() {
        navigationController?.pushViewController(LegacyReaderSettingsViewController(), animated: true)
    }

    private func applyReaderColorSettings() {
        let background = LegacyReaderBackground.current.color
        view.backgroundColor = background
        collectionView.backgroundColor = background
        for case let cell as LegacyPagedImageCell in collectionView.visibleCells {
            cell.applyReaderBackground(background)
        }
        for case let cell as LegacyPagedSpreadCell in collectionView.visibleCells {
            cell.applyReaderBackground(background)
        }
        filterOverlayView.applySettings()
        UIApplication.shared.isIdleTimerDisabled = aidokuLegacyReaderKeepScreenOn()

        let signature = aidokuLegacyReaderImageProcessingSignature()
        if signature != appliedImageSignature {
            appliedImageSignature = signature
            LegacyReaderImagePipeline.shared.clear()
            reloadPreservingCurrentPage()
        }

        // Rebuild spreads when the double-page setting changes.
        if shouldUseDoublePage() != appliedDoublePage {
            rebuildSpreads()
            reloadPreservingCurrentPage()
        }
    }

    private func reloadPreservingCurrentPage(pageIndex explicitPageIndex: Int? = nil) {
        let page = explicitPageIndex ?? currentPageIndex
        collectionView.reloadData()
        if let page = page {
            DispatchQueue.main.async {
                self.scrollTo(pageIndex: page, animated: false)
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        let current = currentPageIndex
        super.viewWillTransition(to: size, with: coordinator)
        // Re-pair spreads for the new orientation when in Automatic double-page.
        let landscape = size.width > size.height
        if LegacyReaderDoublePageMode.current == .auto, appliedDoublePage != landscape {
            rebuildSpreads()
        }
        coordinator.animate(alongsideTransition: nil) { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.reloadData()
            if let current = current {
                self.scrollTo(pageIndex: current, animated: false)
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        trimReaderMemory(keepCurrentPage: true)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        collectionView?.collectionViewLayout.invalidateLayout()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if pages.isEmpty { return 1 }
        return spreads.count + (showsTransitionPage ? 1 : 0)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        return collectionView.bounds.size
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if pages.isEmpty {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: "PagedMessageCell",
                for: indexPath
            ) as! LegacyPagedMessageCell
            cell.configure(message)
            return cell
        }

        switch item(forVisualIndex: indexPath.item) {
            case .transition:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "PagedTransitionCell",
                    for: indexPath
                ) as! LegacyPagedTransitionCell
                configureTransitionView(cell.transitionView)
                return cell
            case .spread(let spreadIndex):
                let spread = spreads.indices.contains(spreadIndex) ? spreads[spreadIndex] : []
                if spread.count >= 2 {
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: "PagedSpreadCell",
                        for: indexPath
                    ) as! LegacyPagedSpreadCell
                    // Lower page index reads first: on the right in RTL, the left in LTR.
                    let leftPageIndex = mode == .pagedRTL ? spread[1] : spread[0]
                    let rightPageIndex = mode == .pagedRTL ? spread[0] : spread[1]
                    cell.configure(
                        leftPage: pages[leftPageIndex],
                        leftPageIndex: leftPageIndex,
                        rightPage: pages[rightPageIndex],
                        rightPageIndex: rightPageIndex,
                        source: source
                    )
                    cell.onImageLoaded = { [weak self] pageIndex, image in
                        self?.markWidePageIfNeeded(index: pageIndex, image: image)
                    }
                    return cell
                }
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "PagedImageCell",
                    for: indexPath
                ) as! LegacyPagedImageCell
                let pageIndex = spread.first ?? 0
                cell.onImageLoaded = { [weak self] image in
                    self?.markWidePageIfNeeded(index: pageIndex, image: image)
                }
                cell.configure(page: pages[pageIndex], source: source)
                return cell
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        if let pageCell = cell as? LegacyPagedImageCell {
            readerTapRecognizer?.require(toFail: pageCell.zoomDoubleTapRecognizer)
        } else if let spreadCell = cell as? LegacyPagedSpreadCell {
            for recognizer in spreadCell.zoomDoubleTapRecognizers {
                readerTapRecognizer?.require(toFail: recognizer)
            }
        }
        guard !pages.isEmpty else { return }
        switch item(forVisualIndex: indexPath.item) {
            case .transition:
                // Keep history/HUD anchored to the last page while the end screen shows.
                if let lastPage = pages.indices.last {
                    currentPageIndex = lastPage
                    recordHistory(pageIndex: lastPage, force: false)
                }
                updatePageHUD()
            case .spread(let spreadIndex):
                let primary = primaryPageIndex(forSpreadIndex: spreadIndex)
                // Record the furthest page in the spread so progress advances.
                let furthest = spreads.indices.contains(spreadIndex) ? (spreads[spreadIndex].last ?? primary) : primary
                currentPageIndex = furthest
                recordHistory(pageIndex: furthest, force: false)
                updatePageHUD()
                flashReaderIfNeeded()
                preloadPages(around: spreads.indices.contains(spreadIndex) ? (spreads[spreadIndex].last ?? primary) : primary, includeCurrent: false)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        if let spreadCell = cell as? LegacyPagedSpreadCell {
            let loadID = spreadCell.currentLoadID
            DispatchQueue.main.asyncAfter(deadline: .now() + aidokuLegacyReaderRetainedPageDelay()) { [weak collectionView, weak spreadCell] in
                guard let collectionView = collectionView, let spreadCell = spreadCell else { return }
                guard collectionView.indexPath(for: spreadCell) == nil else { return }
                spreadCell.releaseDecodedImages(ifLoadID: loadID)
            }
            return
        }
        guard let pageCell = cell as? LegacyPagedImageCell else { return }
        let loadID = pageCell.currentLoadID
        DispatchQueue.main.asyncAfter(deadline: .now() + aidokuLegacyReaderRetainedPageDelay()) { [weak collectionView, weak pageCell] in
            guard let collectionView = collectionView, let pageCell = pageCell else { return }
            guard collectionView.indexPath(for: pageCell) == nil else { return }
            pageCell.releaseDecodedImage(ifLoadID: loadID)
        }
    }

    private func loadPages() {
        if let downloadedPages = LegacyDownloadStore.shared.pages(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key) {
            setPages(downloadedPages)
            message = downloadedPages.isEmpty ? "No downloaded pages." : ""
            collectionView.reloadData()
            scrollToInitialPageIfNeeded()
            updatePageHUD()
            return
        }
        guard !chapter.locked else {
            pages = []
            message = "\(chapter.legacyFormattedTitle) is unavailable from this source."
            collectionView.reloadData()
            return
        }
        source.runner.getPageList(manga: manga, chapter: chapter) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                    case .success(let pages):
                        LegacyZipPageResolver.shared.resolve(pages, source: self.source) { [weak self] resolved in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                self.setPages(resolved)
                                self.message = resolved.isEmpty ? "No pages." : ""
                                self.collectionView.reloadData()
                                self.scrollToInitialPageIfNeeded()
                                self.updatePageHUD()
                            }
                        }
                    case .failure(let error):
                        self.message = self.readerMessage(for: error)
                        self.collectionView.reloadData()
                        self.scrollToInitialPageIfNeeded()
                        self.updatePageHUD()
                }
            }
        }
    }

    private func setPages(_ newPages: [AidokuRunnerLegacyPage]) {
        aidokuLegacyRemoveTemporaryPageDirectories(temporaryPageDirectories)
        temporaryPageDirectories = []
        let prepared = aidokuLegacyPreparePagesForLowMemory(newPages)
        pages = prepared.pages
        temporaryPageDirectories = prepared.temporaryDirectories
        isolatedPageIndexes = []
        knownWidePageIndexes = []
        rebuildSpreads()
        let warmupPageIndex = pages.indices.contains(initialPageIndex) ? initialPageIndex : 0
        preloadPages(around: warmupPageIndex, includeCurrent: true)
    }

    private func shouldUseDoublePage() -> Bool {
        switch LegacyReaderDoublePageMode.current {
            case .off: return false
            case .on: return true
            case .auto:
                // Fall back to the screen when the view isn't laid out yet
                // (e.g. a downloaded chapter loaded during viewDidLoad).
                let size = view.bounds.width > 0 ? view.bounds.size : UIScreen.main.bounds.size
                return size.width > size.height
        }
    }

    /// Groups pages into screens. Single-page mode yields one page per spread
    /// (identical to the original behavior); double-page mode keeps the cover
    /// and loaded wide pages alone, then pairs only adjacent normal pages.
    private func rebuildSpreads() {
        let double = shouldUseDoublePage()
        appliedDoublePage = double
        guard double else {
            spreads = pages.indices.map { [$0] }
            return
        }
        var result: [[Int]] = []
        var index = 0
        while index < pages.count {
            if shouldIsolatePage(at: index) {
                result.append([index])
                index += 1
            } else if index + 1 < pages.count, !shouldIsolatePage(at: index + 1) {
                result.append([index, index + 1])
                index += 2
            } else {
                result.append([index])
                index += 1
            }
        }
        spreads = result
    }

    private func shouldIsolatePage(at index: Int) -> Bool {
        guard pages.indices.contains(index) else { return false }
        return index == 0 || isolatedPageIndexes.contains(index)
    }

    private func markWidePageIfNeeded(index: Int, image: UIImage) {
        guard pages.indices.contains(index), shouldUseDoublePage() else { return }
        let aspectRatio = image.size.width / max(image.size.height, 1)
        guard aspectRatio >= 1.2 else { return }
        guard !knownWidePageIndexes.contains(index) || !isolatedPageIndexes.contains(index) else { return }
        knownWidePageIndexes.insert(index)
        isolatedPageIndexes.insert(index)
        let current = currentPageIndex ?? index
        rebuildSpreads()
        reloadPreservingCurrentPage(pageIndex: current)
    }

    private func scrollToInitialPageIfNeeded() {
        guard !didScrollToInitialPage, pages.indices.contains(initialPageIndex) else { return }
        didScrollToInitialPage = true
        DispatchQueue.main.async {
            self.collectionView.layoutIfNeeded()
            self.scrollTo(pageIndex: self.initialPageIndex, animated: false)
            self.currentPageIndex = self.initialPageIndex
            self.recordHistory(pageIndex: self.initialPageIndex, force: true)
            self.updatePageHUD()
        }
    }

    private func scrollTo(pageIndex: Int, animated: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: visualIndex(forSpreadIndex: spreadIndex(forPageIndex: pageIndex)), section: 0),
            at: .centeredHorizontally,
            animated: animated
        )
    }

    private enum PagedReaderItem {
        case spread(Int)
        case transition
    }

    // The end screen is appended once the pages are loaded. In RTL it sits at
    // the far-left (visual index 0) and shifts the spreads right by one.
    private var showsTransitionPage: Bool {
        return !pages.isEmpty
    }

    private func item(forVisualIndex visualIndex: Int) -> PagedReaderItem {
        if mode == .pagedRTL {
            if showsTransitionPage {
                if visualIndex <= 0 { return .transition }
                let spreadIndex = spreads.count - visualIndex
                return spreads.indices.contains(spreadIndex) ? .spread(spreadIndex) : .transition
            }
            let spreadIndex = spreads.count - 1 - visualIndex
            return spreads.indices.contains(spreadIndex) ? .spread(spreadIndex) : .transition
        }
        if showsTransitionPage && visualIndex >= spreads.count { return .transition }
        return spreads.indices.contains(visualIndex) ? .spread(visualIndex) : .transition
    }

    private func visualIndex(forSpreadIndex spreadIndex: Int) -> Int {
        if mode == .pagedRTL {
            return showsTransitionPage ? max(0, spreads.count - spreadIndex) : max(0, spreads.count - 1 - spreadIndex)
        }
        return spreadIndex
    }

    /// The spread that contains a given page index.
    private func spreadIndex(forPageIndex pageIndex: Int) -> Int {
        for (index, spread) in spreads.enumerated() where spread.contains(pageIndex) {
            return index
        }
        return 0
    }

    /// The representative (first) page of a spread, used for the HUD/history.
    private func primaryPageIndex(forSpreadIndex spreadIndex: Int) -> Int {
        guard spreads.indices.contains(spreadIndex), let first = spreads[spreadIndex].first else { return 0 }
        return first
    }

    /// The page tapped at a given visual index, used by the long-press menu.
    private func pageIndex(forVisualIndex visualIndex: Int) -> Int {
        if case .spread(let spreadIndex) = item(forVisualIndex: visualIndex) {
            return primaryPageIndex(forSpreadIndex: spreadIndex)
        }
        return 0
    }

    private func pageIndex(forVisualIndex visualIndex: Int, in cell: UICollectionViewCell, at collectionPoint: CGPoint) -> Int {
        guard let spreadCell = cell as? LegacyPagedSpreadCell else {
            return pageIndex(forVisualIndex: visualIndex)
        }
        let point = collectionView.convert(collectionPoint, to: spreadCell)
        return spreadCell.pageIndex(at: point) ?? pageIndex(forVisualIndex: visualIndex)
    }

    private var nextChapter: AidokuRunnerLegacyChapter? {
        return legacyReaderNextChapter(after: chapter, in: manga.chapters)
    }

    // The visual page currently centered in the paging collection view.
    private var currentVisualIndex: Int {
        let width = collectionView.bounds.width
        guard width > 0 else { return 0 }
        return Int((collectionView.contentOffset.x + width / 2) / width)
    }

    private var isShowingTransitionPage: Bool {
        guard showsTransitionPage else { return false }
        if case .transition = item(forVisualIndex: currentVisualIndex) { return true }
        return false
    }

    private func configureTransitionView(_ transitionView: LegacyReaderTransitionView) {
        let next = nextChapter
        transitionView.configure(
            finishedTitle: chapter.legacyFormattedTitle,
            finishedUploader: legacyReaderUploaderText(chapter),
            nextTitle: next?.legacyFormattedTitle,
            nextUploader: next.flatMap(legacyReaderUploaderText)
        )
        transitionView.onTapNext = { [weak self] in
            self?.advanceToNextChapter()
        }
    }

    private var previousChapter: AidokuRunnerLegacyChapter? {
        return legacyReaderPreviousChapter(before: chapter, in: manga.chapters)
    }

    private func advanceToNextChapter() {
        guard let next = nextChapter else { return }
        openChapter(next)
    }

    private func goToPreviousChapter() {
        guard let previous = previousChapter else { return }
        openChapter(previous)
    }

    private func openChapter(_ target: AidokuRunnerLegacyChapter) {
        guard let nav = navigationController else { return }
        let reader = LegacyReaderFactory.makeReader(source: source, manga: manga, chapter: target)
        // Replace this reader in the stack so back returns to the manga, not a
        // pile of finished chapters.
        if nav.viewControllers.last === self {
            var stack = nav.viewControllers
            stack[stack.count - 1] = reader
            nav.setViewControllers(stack, animated: true)
        } else {
            nav.pushViewController(reader, animated: true)
        }
    }

    // -1 to load the previous chapter, +1 for the next, set while the user drags
    // past a horizontal edge and acted on when the drag ends.
    private var pendingChapterChange = 0

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isTracking else { return }
        let threshold: CGFloat = 80
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        if scrollView.contentOffset.x < -threshold {
            // Left overscroll: previous chapter in LTR, next chapter in RTL.
            pendingChapterChange = mode == .pagedRTL ? 1 : -1
        } else if scrollView.contentOffset.x > maxX + threshold {
            // Right overscroll: next chapter in LTR, previous chapter in RTL.
            pendingChapterChange = mode == .pagedRTL ? -1 : 1
        } else {
            pendingChapterChange = 0
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let change = pendingChapterChange
        pendingChapterChange = 0
        if change > 0 {
            advanceToNextChapter()
        } else if change < 0 {
            goToPreviousChapter()
        }
    }

    private func preloadPages(around pageIndex: Int, includeCurrent: Bool) {
        let preloadCount = aidokuLegacyReaderPrefetchCount()
        guard preloadCount > 0 || includeCurrent else { return }
        var candidateIndexes = includeCurrent ? [pageIndex] : []
        if preloadCount > 0 {
            candidateIndexes += (1...preloadCount).flatMap { offset -> [Int] in
                return [pageIndex + offset, pageIndex - offset]
            }
        }
        for candidateIndex in candidateIndexes where pages.indices.contains(candidateIndex) {
            guard case .url(let url, let context) = pages[candidateIndex].content else { continue }
            LegacyReaderImagePipeline.shared.preload(url: url, context: context, source: source)
        }
    }

    private func readerMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("missing chapter data") {
            return "This chapter is unavailable from the source."
        }
        return message
    }

    @objc private func toggleBars() {
        barsHidden.toggle()
        navigationController?.setNavigationBarHidden(barsHidden, animated: true)
        overlayView.setControlsHidden(barsHidden, animated: true)
        enforceReaderContainer()
        UIView.animate(withDuration: 0.2, animations: {
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
        })
    }

    @objc private func handleReaderTap(_ recognizer: UITapGestureRecognizer) {
        if isShowingTransitionPage {
            // Tapping anywhere on the end screen advances; the invisible button
            // alone is too small a target to rely on.
            if nextChapter != nil {
                advanceToNextChapter()
            } else {
                toggleBars()
            }
            return
        }
        let location = recognizer.location(in: view)
        let fraction = location.x / max(view.bounds.width, 1)
        // In right-to-left paging the next page sits on the left.
        switch aidokuLegacyReaderTapAction(xFraction: fraction, nextOnLeft: mode == .pagedRTL) {
            case .previous:
                movePage(delta: -1)
            case .next:
                movePage(delta: 1)
            case .menu:
                toggleBars()
        }
    }

    @objc private func handlePageLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !pages.isEmpty else { return }
        let location = recognizer.location(in: collectionView)
        guard
            let indexPath = collectionView.indexPathForItem(at: location),
            let cell = collectionView.cellForItem(at: indexPath),
            pages.indices.contains(pageIndex(forVisualIndex: indexPath.item, in: cell, at: location))
        else { return }
        let pageIndex = pageIndex(forVisualIndex: indexPath.item, in: cell, at: location)
        let point = recognizer.location(in: view)
        showPageActions(
            pageIndex: pageIndex,
            sourceView: view,
            sourceRect: CGRect(origin: point, size: CGSize(width: 1, height: 1))
        )
    }

    @objc private func showCurrentPageActions() {
        guard !pages.isEmpty else { return }
        let pageIndex = currentPageIndex ?? initialPageIndex
        guard pages.indices.contains(pageIndex) else { return }
        showPageActions(pageIndex: pageIndex, sourceView: view, sourceRect: topBarAnchorRect)
    }

    private var topBarAnchorRect: CGRect {
        return CGRect(x: view.bounds.maxX - 40, y: max(8, view.safeAreaInsets.top), width: 1, height: 1)
    }

    @objc private func openChapterWebPage() {
        guard let url = aidokuLegacyChapterWebURL(chapter) else { return }
        aidokuLegacyOpenWebPage(url: url, title: chapter.legacyFormattedTitle, from: self)
    }

    private func showPageActions(pageIndex: Int, sourceView: UIView?, sourceRect: CGRect? = nil) {
        guard pages.indices.contains(pageIndex) else { return }
        let indexPath = IndexPath(item: visualIndex(forSpreadIndex: spreadIndex(forPageIndex: pageIndex)), section: 0)
        let visibleCell = collectionView.cellForItem(at: indexPath)
        let visibleImage = (visibleCell as? LegacyPagedImageCell)?.currentImage
            ?? (visibleCell as? LegacyPagedSpreadCell)?.currentImage(for: pageIndex)
        resolvePageActionImage(page: pages[pageIndex], visibleImage: visibleImage) { [weak self] image in
            guard let self = self else { return }
            self.resolvePageDescription(pageIndex: pageIndex) { [weak self] pageDescription in
                guard let self = self else { return }
                guard image != nil || pageDescription != nil else {
                    self.showLegacyReaderAlert(title: "No Image", message: "This page image is not available yet.")
                    return
                }
                LegacyReaderPageActionPresenter.present(
                    image: image,
                    pageDescription: pageDescription,
                    pageIndex: pageIndex,
                    from: self,
                    sourceView: sourceView ?? self.view,
                    sourceRect: sourceRect
                )
            }
        }
    }

    private func resolvePageDescription(
        pageIndex: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard pages.indices.contains(pageIndex) else {
            completion(nil)
            return
        }
        aidokuLegacyResolvePageDescription(for: pages[pageIndex], runner: source.runner) { [weak self] description in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let description = description, self.pages.indices.contains(pageIndex) {
                    self.pages[pageIndex].description = description
                    self.pages[pageIndex].hasDescription = true
                }
                completion(description)
            }
        }
    }

    private func resolvePageActionImage(
        page: AidokuRunnerLegacyPage,
        visibleImage: UIImage?,
        completion: @escaping (UIImage?) -> Void
    ) {
        if let visibleImage = visibleImage {
            completion(visibleImage)
            return
        }
        switch page.content {
            case .url(let url, let context):
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source, completion: completion)
            case .image(let data):
                aidokuLegacyImageDecodeQueue.async {
                    let image = autoreleasepool {
                        LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: aidokuLegacyReaderMaxPixelHeight())
                            .map(aidokuLegacyPrepareReaderImageForDisplay)
                    }
                    DispatchQueue.main.async {
                        completion(image)
                    }
                }
            case .text(_), .zipFile(_, _):
                completion(nil)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return shouldHandleReaderTap(from: touch)
    }

    private func shouldHandleReaderTap(from touch: UITouch) -> Bool {
        var view = touch.view
        while let currentView = view {
            if currentView is UIControl {
                // Let the end-screen "next chapter" button handle its own tap.
                return false
            }
            if let zoomableView = currentView as? LegacyZoomableImageView {
                return !zoomableView.isZoomed
            }
            view = currentView.superview
        }
        return true
    }

    private func movePage(delta: Int) {
        guard !pages.isEmpty, !spreads.isEmpty else { return }
        // Move one spread (screen) at a time so double-page taps advance by two.
        let currentSpread = spreadIndex(forPageIndex: currentPageIndex ?? initialPageIndex)
        let nextSpread = min(max(currentSpread + delta, 0), spreads.count - 1)
        guard nextSpread != currentSpread else {
            overlayView.showGuide(modeTitle: mode.title, nextOnLeft: mode == .pagedRTL)
            return
        }
        let targetPage = primaryPageIndex(forSpreadIndex: nextSpread)
        let furthestPage = spreads[nextSpread].last ?? targetPage
        scrollTo(pageIndex: targetPage, animated: aidokuLegacyReaderAnimatePageTransitions())
        currentPageIndex = furthestPage
        recordHistory(pageIndex: furthestPage, force: false)
        updatePageHUD()
        flashReaderIfNeeded()
    }

    private func jumpToPage(_ pageIndex: Int, animated: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        scrollTo(pageIndex: pageIndex, animated: animated)
        currentPageIndex = pageIndex
        preloadPages(around: pageIndex, includeCurrent: true)
        recordHistory(pageIndex: pageIndex, force: true)
        updatePageHUD()
        flashReaderIfNeeded()
    }

    private func installOverlayIfNeeded() {
        if let hostView = navigationController?.view ?? view {
            aidokuLegacyInstallReaderFilterOverlay(
                filterOverlayView,
                host: hostView,
                navigationBar: navigationController?.navigationBar
            )
        }
        guard overlayView.superview == nil else { return }
        guard let hostView = navigationController?.view ?? view else { return }
        overlayView.onPageSelected = { [weak self] pageIndex in
            self?.jumpToPage(pageIndex, animated: false)
        }
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
        overlayView.setControlsHidden(barsHidden, animated: false)
        updatePageHUD()
    }

    private func showTapOverlayIfNeeded() {
        guard aidokuLegacyReaderShowsTapZones(), LegacyReaderNavLayout.current != .disabled, !didShowTapOverlay else { return }
        didShowTapOverlay = true
        overlayView.showGuide(modeTitle: mode.title, nextOnLeft: mode == .pagedRTL)
    }

    private func updatePageHUD() {
        overlayView.updatePage(index: currentPageIndex, count: pages.count)
    }

    private func flashReaderIfNeeded() {
        guard aidokuLegacyReaderEInkFlash(), view.window != nil else { return }
        if let pageIndex = currentPageIndex {
            guard lastEInkFlashPageIndex != pageIndex else { return }
            lastEInkFlashPageIndex = pageIndex
        }
        let flashView: UIView
        if let existing = eInkFlashView {
            flashView = existing
        } else {
            flashView = UIView(frame: view.bounds)
            flashView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            flashView.isUserInteractionEnabled = false
            flashView.alpha = 0
            view.addSubview(flashView)
            eInkFlashView = flashView
        }
        flashView.backgroundColor = LegacyReaderBackground.current == .white ? UIColor.black : UIColor.white
        view.bringSubviewToFront(flashView)
        flashView.alpha = 0.85
        UIView.animate(withDuration: 0.12, delay: 0.03, options: [.allowUserInteraction], animations: {
            flashView.alpha = 0
        })
    }

    private func registerAppStateObservers() {
        let center = NotificationCenter.default
        appStateObservers.append(
            center.addObserver(forName: .legacyReaderColorSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.applyReaderColorSettings()
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyMemoryTrimRequested, object: nil, queue: .main) { [weak self] _ in
                self?.trimReaderMemory(keepCurrentPage: true)
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
        )
        appStateObservers.append(
            center.addObserver(forName: .legacyAppWillEnterForeground, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppWillEnterForeground()
            }
        )
    }

    private func handleAppDidEnterBackground() {
        if let currentPageIndex = currentPageIndex {
            recordHistory(pageIndex: currentPageIndex, force: true)
        }
        didTrimVisibleImagesForBackground = true
        trimReaderMemory(keepCurrentPage: false)
    }

    private func handleAppWillEnterForeground() {
        guard didTrimVisibleImagesForBackground else { return }
        didTrimVisibleImagesForBackground = false
        let pageIndex = currentPageIndex
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        guard let pageIndex = pageIndex, pages.indices.contains(pageIndex) else { return }
        DispatchQueue.main.async {
            self.scrollTo(pageIndex: pageIndex, animated: false)
            self.currentPageIndex = pageIndex
            self.updatePageHUD()
        }
    }

    private func trimReaderMemory(keepCurrentPage: Bool) {
        let current = keepCurrentPage ? currentPageIndex : nil
        for cell in collectionView.visibleCells {
            guard let pageCell = cell as? LegacyPagedImageCell else { continue }
            let indexPath = collectionView.indexPath(for: cell)
            let visiblePageIndex: Int?
            if let indexPath = indexPath {
                visiblePageIndex = pageIndex(forVisualIndex: indexPath.item)
            } else {
                visiblePageIndex = nil
            }
            if visiblePageIndex != current {
                pageCell.releaseDecodedImage()
            }
        }
        aidokuLegacyTrimVolatileCaches()
    }

    private func enforceReaderContainer(relayout: Bool = true) {
        tabBarController?.tabBar.isHidden = true
        guard relayout else { return }
        tabBarController?.view.setNeedsLayout()
        tabBarController?.view.layoutIfNeeded()
    }

    private func recordHistory(pageIndex: Int, force: Bool) {
        guard pages.indices.contains(pageIndex) else { return }
        let now = Date()
        if force {
            pendingHistorySaveWorkItem?.cancel()
            pendingHistorySaveWorkItem = nil
        } else {
            if lastSavedHistoryPageIndex == pageIndex {
                return
            }
            let saveDelay = 2 - now.timeIntervalSince(lastHistorySaveDate)
            if saveDelay > 0 {
                pendingHistorySaveWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard self?.currentPageIndex == pageIndex else { return }
                    self?.recordHistory(pageIndex: pageIndex, force: true)
                }
                pendingHistorySaveWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: workItem)
                return
            }
        }
        pendingHistorySaveWorkItem?.cancel()
        pendingHistorySaveWorkItem = nil
        // Incognito mode: skip all persistence (history, stats, resume session,
        // tracker sync) but keep throttle bookkeeping so we do not re-schedule.
        if aidokuLegacyIncognitoEnabled() {
            lastSavedHistoryPageIndex = pageIndex
            lastHistorySaveDate = now
            return
        }
        LegacyHistoryStore.shared.update(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        // Push read progress to a linked tracker. No-op when not logged in,
        // not linked, or the chapter is not ahead of stored progress.
        LegacyTrackerManager.shared.syncProgress(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapterNumber: chapter.chapterNumber ?? 0
        )
        LegacyReaderSessionStore.shared.save(
            source: source,
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pages.count
        )
        LegacyReadingStatsStore.shared.recordChapterRead(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapterKey: chapter.key
        )
        runDownloadAutomationIfFinished(pageIndex: pageIndex)
        lastSavedHistoryPageIndex = pageIndex
        lastHistorySaveDate = now
    }

    private func runDownloadAutomationIfFinished(pageIndex: Int) {
        guard !didRunDownloadAutomation, pageIndex >= pages.count - 1 else { return }
        didRunDownloadAutomation = true
        LegacyDownloadAutomation.shared.chapterDidComplete(
            source: source,
            manga: manga,
            chapter: chapter,
            nextUnreadChapter: legacyReaderNextUnreadChapter(
                after: chapter,
                in: manga.chapters,
                sourceKey: source.key,
                mangaKey: manga.key
            )
        )
    }
}

private final class LegacyPagedMessageCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white
        label.textAlignment = .center
        label.numberOfLines = 0
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ message: String) {
        label.text = message
    }
}

// Sort chapters into reading order (oldest first). Free function so both the
// detail screen and the readers share one definition.
func legacyChapterAscending(_ lhs: AidokuRunnerLegacyChapter, _ rhs: AidokuRunnerLegacyChapter) -> Bool {
    if let lhsVolume = lhs.volumeNumber, let rhsVolume = rhs.volumeNumber, lhsVolume != rhsVolume {
        return lhsVolume < rhsVolume
    }
    if lhs.volumeNumber != nil && rhs.volumeNumber == nil {
        return true
    }
    if lhs.volumeNumber == nil && rhs.volumeNumber != nil {
        return false
    }
    if let lhsChapter = lhs.chapterNumber, let rhsChapter = rhs.chapterNumber, lhsChapter != rhsChapter {
        return lhsChapter < rhsChapter
    }
    if lhs.chapterNumber != nil && rhs.chapterNumber == nil {
        return true
    }
    if lhs.chapterNumber == nil && rhs.chapterNumber != nil {
        return false
    }
    if let lhsDate = lhs.dateUploaded, let rhsDate = rhs.dateUploaded, lhsDate != rhsDate {
        return lhsDate < rhsDate
    }
    return lhs.legacyFormattedTitle.localizedStandardCompare(rhs.legacyFormattedTitle) == .orderedAscending
}

// The chapter that follows `current` in reading order, honoring the current
// chapter's language so we do not jump across translations. Returns nil when
// there is no readable next chapter (end of series, locked, or no list).
private func legacyReaderNextChapter(
    after current: AidokuRunnerLegacyChapter,
    in chapters: [AidokuRunnerLegacyChapter]?
) -> AidokuRunnerLegacyChapter? {
    guard let chapters = chapters, !chapters.isEmpty else { return nil }
    let language = current.normalizedLanguage
    let pool = chapters.filter { language == nil || $0.normalizedLanguage == language || $0.normalizedLanguage == nil }
    let sorted = (pool.isEmpty ? chapters : pool).sorted(by: legacyChapterAscending)
    guard let index = sorted.firstIndex(where: { $0.key == current.key }) else { return nil }
    let nextIndex = index + 1
    guard sorted.indices.contains(nextIndex) else { return nil }
    let candidate = sorted[nextIndex]
    return candidate.locked ? nil : candidate
}

private func legacyReaderNextUnreadChapter(
    after current: AidokuRunnerLegacyChapter,
    in chapters: [AidokuRunnerLegacyChapter]?,
    sourceKey: String,
    mangaKey: String
) -> AidokuRunnerLegacyChapter? {
    guard let chapters = chapters, !chapters.isEmpty else { return nil }
    let language = current.normalizedLanguage
    let pool = chapters.filter { language == nil || $0.normalizedLanguage == language || $0.normalizedLanguage == nil }
    let sorted = (pool.isEmpty ? chapters : pool).sorted(by: legacyChapterAscending)
    guard let index = sorted.firstIndex(where: { $0.key == current.key }) else { return nil }
    let readKeys = LegacyHistoryStore.shared.readChapterKeys(sourceKey: sourceKey, mangaKey: mangaKey)
    for candidate in sorted.dropFirst(index + 1) where !candidate.locked {
        if readKeys.contains(candidate.key) { continue }
        if LegacyDownloadStore.shared.hasChapter(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: candidate.key) { continue }
        return candidate
    }
    return nil
}

// The chapter that precedes `current` in reading order. Mirrors
// `legacyReaderNextChapter` but steps backward.
private func legacyReaderPreviousChapter(
    before current: AidokuRunnerLegacyChapter,
    in chapters: [AidokuRunnerLegacyChapter]?
) -> AidokuRunnerLegacyChapter? {
    guard let chapters = chapters, !chapters.isEmpty else { return nil }
    let language = current.normalizedLanguage
    let pool = chapters.filter { language == nil || $0.normalizedLanguage == language || $0.normalizedLanguage == nil }
    let sorted = (pool.isEmpty ? chapters : pool).sorted(by: legacyChapterAscending)
    guard let index = sorted.firstIndex(where: { $0.key == current.key }) else { return nil }
    let previousIndex = index - 1
    guard sorted.indices.contains(previousIndex) else { return nil }
    let candidate = sorted[previousIndex]
    return candidate.locked ? nil : candidate
}

private func legacyReaderUploaderText(_ chapter: AidokuRunnerLegacyChapter) -> String? {
    guard
        let scanlators = chapter.scanlators?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }),
        !scanlators.isEmpty
    else {
        return nil
    }
    return scanlators.joined(separator: ", ")
}

// End-of-chapter "transition" screen shown after the last page: which chapter
// just finished and which one is next (tappable to continue).
private final class LegacyReaderTransitionView: UIView {
    private let stack = UIStackView()
    private let finishedHeader = UILabel()
    private let finishedTitle = UILabel()
    private let finishedUploader = UILabel()
    private let finishedGroup = UIStackView()
    private let nextHeader = UILabel()
    private let nextTitle = UILabel()
    private let nextUploader = UILabel()
    private let nextGroup = UIStackView()
    private let noNextLabel = UILabel()
    private let nextButton = UIButton(type: .custom)

    var onTapNext: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black

        configureHeader(finishedHeader, text: "Finished:")
        configureTitle(finishedTitle)
        configureSubtitle(finishedUploader)
        configureHeader(nextHeader, text: "Next:")
        configureTitle(nextTitle)
        configureSubtitle(nextUploader)
        configureSubtitle(noNextLabel)
        noNextLabel.text = "There's no next chapter."

        finishedGroup.axis = .vertical
        finishedGroup.alignment = .fill
        finishedGroup.spacing = 6
        finishedGroup.addArrangedSubview(finishedHeader)
        finishedGroup.addArrangedSubview(finishedTitle)
        finishedGroup.addArrangedSubview(finishedUploader)

        nextGroup.axis = .vertical
        nextGroup.alignment = .fill
        nextGroup.spacing = 6
        nextGroup.addArrangedSubview(nextHeader)
        nextGroup.addArrangedSubview(nextTitle)
        nextGroup.addArrangedSubview(nextUploader)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 36
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(finishedGroup)
        stack.addArrangedSubview(nextGroup)
        stack.addArrangedSubview(noNextLabel)
        addSubview(stack)

        // Invisible button covering the next-chapter block so a tap there
        // advances. Sitting on top keeps the labels untouched while still being
        // a UIControl, which the reader's tap recognizer ignores.
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)
        addSubview(nextButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),

            nextButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            nextButton.topAnchor.constraint(equalTo: nextGroup.topAnchor, constant: -14),
            nextButton.bottomAnchor.constraint(equalTo: nextGroup.bottomAnchor, constant: 14)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func didTapNext() {
        onTapNext?()
    }

    func configure(
        finishedTitle: String,
        finishedUploader: String?,
        nextTitle: String?,
        nextUploader: String?
    ) {
        self.finishedTitle.text = finishedTitle
        if let finishedUploader = finishedUploader, !finishedUploader.isEmpty {
            self.finishedUploader.text = "Uploaded by \(finishedUploader)"
            self.finishedUploader.isHidden = false
        } else {
            self.finishedUploader.isHidden = true
        }

        if let nextTitle = nextTitle {
            self.nextTitle.text = nextTitle
            if let nextUploader = nextUploader, !nextUploader.isEmpty {
                self.nextUploader.text = "Uploaded by \(nextUploader)"
                self.nextUploader.isHidden = false
            } else {
                self.nextUploader.isHidden = true
            }
            nextGroup.isHidden = false
            noNextLabel.isHidden = true
            nextButton.isHidden = false
            nextButton.isUserInteractionEnabled = true
        } else {
            nextGroup.isHidden = true
            noNextLabel.isHidden = false
            nextButton.isHidden = true
            nextButton.isUserInteractionEnabled = false
        }
    }

    private func configureHeader(_ label: UILabel, text: String) {
        label.text = text
        label.textColor = UIColor.white
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.numberOfLines = 0
    }

    private func configureTitle(_ label: UILabel) {
        label.textColor = UIColor.white
        label.font = UIFont.systemFont(ofSize: 26, weight: .regular)
        label.numberOfLines = 0
    }

    private func configureSubtitle(_ label: UILabel) {
        label.textColor = UIColor(white: 0.55, alpha: 1)
        label.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        label.numberOfLines = 0
    }
}

private final class LegacyPagedTransitionCell: UICollectionViewCell {
    let transitionView = LegacyReaderTransitionView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black
        transitionView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(transitionView)
        NSLayoutConstraint.activate([
            transitionView.topAnchor.constraint(equalTo: contentView.topAnchor),
            transitionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            transitionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            transitionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        transitionView.onTapNext = nil
    }
}

private final class LegacyReaderTransitionTableCell: UITableViewCell {
    let transitionView = LegacyReaderTransitionView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor.black
        contentView.backgroundColor = UIColor.black
        selectionStyle = .none
        transitionView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(transitionView)
        NSLayoutConstraint.activate([
            transitionView.topAnchor.constraint(equalTo: contentView.topAnchor),
            transitionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            transitionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            transitionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        transitionView.onTapNext = nil
    }
}

/// Full-screen, non-interactive overlay that applies the cheap reader color
/// effects (brightness dimming, color filter tint, invert) as blended layers
/// above the page content and below the navigation bar / reader controls.
private final class LegacyReaderFilterOverlayView: UIView {
    private let colorTintView = UIView()
    private let brightnessView = UIView()
    private let invertView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for effect in [colorTintView, brightnessView, invertView] {
            effect.translatesAutoresizingMaskIntoConstraints = false
            effect.isUserInteractionEnabled = false
            effect.isHidden = true
            addSubview(effect)
            NSLayoutConstraint.activate([
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        invertView.backgroundColor = .white
        applySettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applySettings() {
        if aidokuLegacyReaderColorFilterEnabled() {
            colorTintView.isHidden = false
            colorTintView.backgroundColor = aidokuLegacyReaderColorFilterColor()
            if let blendName = LegacyReaderBlendMode.current.compositingFilterName {
                colorTintView.layer.compositingFilter = blendName
            } else {
                colorTintView.layer.compositingFilter = nil
            }
        } else {
            colorTintView.isHidden = true
            colorTintView.layer.compositingFilter = nil
        }

        let brightness = aidokuLegacyReaderBrightness()
        if brightness > 0.001 {
            brightnessView.isHidden = false
            brightnessView.backgroundColor = UIColor(white: 0, alpha: brightness)
        } else {
            brightnessView.isHidden = true
        }

        if aidokuLegacyReaderInvert() {
            invertView.isHidden = false
            invertView.layer.compositingFilter = "differenceBlendMode"
        } else {
            invertView.isHidden = true
            invertView.layer.compositingFilter = nil
        }
    }
}

/// Installs the reader color filter overlay into the host view, below the
/// navigation bar so the bar and reader controls stay un-tinted.
private func aidokuLegacyInstallReaderFilterOverlay(
    _ overlay: LegacyReaderFilterOverlayView,
    host hostView: UIView,
    navigationBar: UINavigationBar?
) {
    guard overlay.superview == nil else { return }
    overlay.translatesAutoresizingMaskIntoConstraints = false
    if let navBar = navigationBar, navBar.superview === hostView {
        hostView.insertSubview(overlay, belowSubview: navBar)
    } else {
        hostView.addSubview(overlay)
    }
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: hostView.topAnchor),
        overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
        overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
    ])
    overlay.applySettings()
}

/// A labeled slider row used by the reader settings screen.
private final class LegacyReaderSliderCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    var onChange: ((Float) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = LegacyPalette.panel
        selectionStyle = .none
        titleLabel.font = .systemFont(ofSize: 15)
        titleLabel.textColor = LegacyPalette.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.textColor = LegacyPalette.secondaryText
        valueLabel.textAlignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)
        contentView.addSubview(slider)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        value: Float,
        minimumValue: Float,
        maximumValue: Float,
        tint: UIColor,
        display: @escaping (Float) -> String
    ) {
        titleLabel.text = title
        slider.minimumValue = minimumValue
        slider.maximumValue = maximumValue
        slider.value = value
        slider.minimumTrackTintColor = tint
        valueLabel.text = display(value)
        self.display = display
    }

    private var display: ((Float) -> String)?

    @objc private func sliderChanged() {
        valueLabel.text = display?(slider.value)
        onChange?(slider.value)
    }
}

/// A labeled switch row used by the reader settings screen.
private final class LegacyReaderToggleCell: UITableViewCell {
    private let toggle = UISwitch()
    var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        backgroundColor = LegacyPalette.panel
        textLabel?.textColor = LegacyPalette.primaryText
        detailTextLabel?.textColor = LegacyPalette.secondaryText
        detailTextLabel?.numberOfLines = 0
        selectionStyle = .none
        toggle.onTintColor = LegacyPalette.accent
        toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)
        accessoryView = toggle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String?, isOn: Bool) {
        textLabel?.text = title
        detailTextLabel?.text = subtitle
        toggle.isOn = isOn
    }

    @objc private func toggled() {
        onToggle?(toggle.isOn)
    }
}

/// Mihon-style in-reader settings: page background, brightness, color filter
/// (RGBA + blend mode), grayscale, invert, page number, tap zones, keep screen on.
private final class LegacyReaderSettingsViewController: UITableViewController {
    private enum Item {
        case background
        case navLayout
        case invertTapZones
        case brightness
        case colorFilterEnabled
        case colorRed
        case colorGreen
        case colorBlue
        case colorAlpha
        case blendMode
        case grayscale
        case invert
        case cropBorders
        case pageNumber
        case tapZones
        case pageTransitions
        case keepScreenOn
        case doublePage
        case eInkFlash
        case sidePadding
    }

    private struct Section {
        let title: String?
        let footer: String?
        let items: [Item]
    }

    private var sections: [Section] = []

    init() {
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reader Settings"
        view.backgroundColor = LegacyPalette.background
        tableView.backgroundColor = LegacyPalette.background
        navigationController?.navigationBar.tintColor = LegacyPalette.accent
        rebuildSections(reload: false)
    }

    private func rebuildSections(reload: Bool) {
        var colorItems: [Item] = [.brightness, .colorFilterEnabled]
        if aidokuLegacyReaderColorFilterEnabled() {
            colorItems += [.colorRed, .colorGreen, .colorBlue, .colorAlpha, .blendMode]
        }
        sections = [
            Section(title: "Background", footer: nil, items: [.background]),
            Section(
                title: "Navigation",
                footer: "How taps turn pages in the reader.",
                items: [.navLayout, .invertTapZones]
            ),
            Section(
                title: "Color Filter",
                footer: "Tint or dim pages. Blend modes mix the tint with the page color.",
                items: colorItems
            ),
            Section(
                title: "Display",
                footer: "Grayscale and crop borders re-decode pages and use more CPU.",
                items: [.grayscale, .invert, .cropBorders, .pageNumber, .tapZones, .pageTransitions, .keepScreenOn]
            ),
            Section(
                title: "Paged Reader",
                footer: "Double page shows two pages side by side in paged modes. E-ink flash briefly refreshes the page after navigation.",
                items: [.doublePage, .eInkFlash]
            ),
            Section(
                title: "Vertical Scroll",
                footer: "Narrows continuous-scroll pages on wide screens like iPad.",
                items: [.sidePadding]
            )
        ]
        if reload {
            tableView.reloadData()
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .legacyReaderColorSettingsDidChange, object: nil)
    }

    private func item(at indexPath: IndexPath) -> Item {
        return sections[indexPath.section].items[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch item(at: indexPath) {
            case .background:
                let cell = valueCell()
                cell.textLabel?.text = "Page Background"
                cell.detailTextLabel?.text = LegacyReaderBackground.current.title
                return cell
            case .blendMode:
                let cell = valueCell()
                cell.textLabel?.text = "Blend Mode"
                cell.detailTextLabel?.text = LegacyReaderBlendMode.current.title
                return cell
            case .sidePadding:
                let cell = valueCell()
                let percent = aidokuLegacyReaderWebtoonSidePaddingPercent()
                cell.textLabel?.text = "Side Padding"
                cell.detailTextLabel?.text = percent == 0 ? "Off" : "\(percent)%"
                return cell
            case .doublePage:
                let cell = valueCell()
                cell.textLabel?.text = "Double Page"
                cell.detailTextLabel?.text = LegacyReaderDoublePageMode.current.title
                return cell
            case .eInkFlash:
                let cell = toggleCell()
                cell.configure(title: "E-Ink Flash", subtitle: "Flash the page surface after paged-reader navigation.", isOn: aidokuLegacyReaderEInkFlash())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderEInkFlash(isOn)
                    self?.notifyChange()
                }
                return cell
            case .navLayout:
                let cell = valueCell()
                cell.textLabel?.text = "Tap Zones Layout"
                cell.detailTextLabel?.text = LegacyReaderNavLayout.current.title
                return cell
            case .invertTapZones:
                let cell = toggleCell()
                cell.configure(title: "Invert Tap Zones", subtitle: "Swap the previous/next sides.", isOn: aidokuLegacyReaderInvertTapZones())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderInvertTapZones(isOn)
                    self?.notifyChange()
                }
                return cell
            case .brightness:
                let cell = sliderCell()
                cell.configure(
                    title: "Brightness",
                    value: Float(aidokuLegacyReaderBrightness()),
                    minimumValue: 0,
                    maximumValue: 0.9,
                    tint: LegacyPalette.accent,
                    display: { $0 < 0.005 ? "Off" : "\(Int(($0 / 0.9) * 100))%" }
                )
                cell.onChange = { [weak self] value in
                    aidokuLegacySetReaderBrightness(CGFloat(value))
                    self?.notifyChange()
                }
                return cell
            case .colorRed:
                return colorSliderCell(title: "Red", key: aidokuLegacyReaderColorFilterRedKey, value: aidokuLegacyReaderColorComponents().red, tint: UIColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
            case .colorGreen:
                return colorSliderCell(title: "Green", key: aidokuLegacyReaderColorFilterGreenKey, value: aidokuLegacyReaderColorComponents().green, tint: UIColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
            case .colorBlue:
                return colorSliderCell(title: "Blue", key: aidokuLegacyReaderColorFilterBlueKey, value: aidokuLegacyReaderColorComponents().blue, tint: UIColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
            case .colorAlpha:
                return colorSliderCell(title: "Strength", key: aidokuLegacyReaderColorFilterAlphaKey, value: aidokuLegacyReaderColorComponents().alpha, tint: LegacyPalette.accent)
            case .colorFilterEnabled:
                let cell = toggleCell()
                cell.configure(title: "Color Filter", subtitle: nil, isOn: aidokuLegacyReaderColorFilterEnabled())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderColorFilterEnabled(isOn)
                    self?.rebuildSections(reload: false)
                    self?.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
                    self?.notifyChange()
                }
                return cell
            case .grayscale:
                let cell = toggleCell()
                cell.configure(title: "Grayscale", subtitle: "Show pages in black and white.", isOn: aidokuLegacyReaderGrayscale())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderGrayscale(isOn)
                    self?.notifyChange()
                }
                return cell
            case .invert:
                let cell = toggleCell()
                cell.configure(title: "Invert Colors", subtitle: "Invert page colors (useful for dark scans).", isOn: aidokuLegacyReaderInvert())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderInvert(isOn)
                    self?.notifyChange()
                }
                return cell
            case .cropBorders:
                let cell = toggleCell()
                cell.configure(title: "Crop Borders", subtitle: "Trim solid margins around each page.", isOn: aidokuLegacyReaderCropBorders())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderCropBorders(isOn)
                    self?.notifyChange()
                }
                return cell
            case .pageNumber:
                let cell = toggleCell()
                cell.configure(title: "Page Number", subtitle: "Show the page count in the reader.", isOn: aidokuLegacyReaderShowsPageNumber())
                cell.onToggle = { [weak self] isOn in
                    UserDefaults.standard.set(isOn, forKey: "AidokuLegacy.reader.showPageNumber")
                    self?.notifyChange()
                }
                return cell
            case .tapZones:
                let cell = toggleCell()
                cell.configure(title: "Tap Zones Overlay", subtitle: "Briefly show previous and next tap zones.", isOn: aidokuLegacyReaderShowsTapZones())
                cell.onToggle = { [weak self] isOn in
                    UserDefaults.standard.set(isOn, forKey: "AidokuLegacy.reader.showTapZones")
                    self?.notifyChange()
                }
                return cell
            case .pageTransitions:
                let cell = toggleCell()
                cell.configure(title: "Animate Page Transitions", subtitle: "Slide when tapping to the next or previous page.", isOn: aidokuLegacyReaderAnimatePageTransitions())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderAnimatePageTransitions(isOn)
                    self?.notifyChange()
                }
                return cell
            case .keepScreenOn:
                let cell = toggleCell()
                cell.configure(title: "Keep Screen On", subtitle: "Prevent the screen from sleeping while reading.", isOn: aidokuLegacyReaderKeepScreenOn())
                cell.onToggle = { [weak self] isOn in
                    aidokuLegacySetReaderKeepScreenOn(isOn)
                    self?.notifyChange()
                }
                return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch item(at: indexPath) {
            case .background:
                presentBackgroundPicker(at: indexPath)
            case .blendMode:
                presentBlendModePicker(at: indexPath)
            case .sidePadding:
                presentSidePaddingPicker(at: indexPath)
            case .navLayout:
                presentNavLayoutPicker(at: indexPath)
            case .doublePage:
                presentDoublePagePicker(at: indexPath)
            default:
                break
        }
    }

    private func presentDoublePagePicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "Double Page", message: nil, preferredStyle: .actionSheet)
        for mode in LegacyReaderDoublePageMode.allCases {
            let title = mode == LegacyReaderDoublePageMode.current ? "\(mode.title) (Current)" : mode.title
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                LegacyReaderDoublePageMode.setCurrent(mode)
                self.tableView.reloadRows(at: [indexPath], with: .automatic)
                self.notifyChange()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func presentNavLayoutPicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "Tap Zones Layout", message: nil, preferredStyle: .actionSheet)
        for layout in LegacyReaderNavLayout.allCases {
            let title = layout == LegacyReaderNavLayout.current ? "\(layout.title) (Current)" : layout.title
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                LegacyReaderNavLayout.setCurrent(layout)
                self.tableView.reloadRows(at: [indexPath], with: .automatic)
                self.notifyChange()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func presentSidePaddingPicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "Side Padding", message: nil, preferredStyle: .actionSheet)
        let current = aidokuLegacyReaderWebtoonSidePaddingPercent()
        for percent in [0, 5, 10, 15, 25] {
            let label = percent == 0 ? "Off" : "\(percent)%"
            let title = percent == current ? "\(label) (Current)" : label
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                aidokuLegacySetReaderWebtoonSidePaddingPercent(percent)
                self.tableView.reloadRows(at: [indexPath], with: .automatic)
                self.notifyChange()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func presentBackgroundPicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "Page Background", message: nil, preferredStyle: .actionSheet)
        for option in LegacyReaderBackground.allCases {
            let title = option == LegacyReaderBackground.current ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                LegacyReaderBackground.setCurrent(option)
                self.tableView.reloadRows(at: [indexPath], with: .automatic)
                self.notifyChange()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func presentBlendModePicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "Blend Mode", message: nil, preferredStyle: .actionSheet)
        for option in LegacyReaderBlendMode.allCases {
            let title = option == LegacyReaderBlendMode.current ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                LegacyReaderBlendMode.setCurrent(option)
                self.tableView.reloadRows(at: [indexPath], with: .automatic)
                self.notifyChange()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(alert, at: indexPath)
    }

    private func presentSheet(_ alert: UIAlertController, at indexPath: IndexPath) {
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = tableView
                popover.sourceRect = tableView.rectForRow(at: indexPath)
            }
        }
        present(alert, animated: true)
    }

    private func valueCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "value")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "value")
        cell.backgroundColor = LegacyPalette.panel
        cell.textLabel?.textColor = LegacyPalette.primaryText
        cell.detailTextLabel?.textColor = LegacyPalette.secondaryText
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    private func sliderCell() -> LegacyReaderSliderCell {
        return (tableView.dequeueReusableCell(withIdentifier: "slider") as? LegacyReaderSliderCell)
            ?? LegacyReaderSliderCell(style: .default, reuseIdentifier: "slider")
    }

    private func toggleCell() -> LegacyReaderToggleCell {
        return (tableView.dequeueReusableCell(withIdentifier: "toggle") as? LegacyReaderToggleCell)
            ?? LegacyReaderToggleCell(style: .subtitle, reuseIdentifier: "toggle")
    }

    private func colorSliderCell(title: String, key: String, value: Int, tint: UIColor) -> LegacyReaderSliderCell {
        let cell = sliderCell()
        cell.configure(
            title: title,
            value: Float(value),
            minimumValue: 0,
            maximumValue: 255,
            tint: tint,
            display: { "\(Int($0.rounded()))" }
        )
        cell.onChange = { [weak self] newValue in
            aidokuLegacySetReaderColorComponent(key, value: Int(newValue.rounded()))
            self?.notifyChange()
        }
        return cell
    }
}

private final class LegacyReaderOverlayView: UIView {
    private static let prevZoneColor = UIColor.orange.withAlphaComponent(0.55)
    private static let nextZoneColor = UIColor.green.withAlphaComponent(0.50)

    private let leftZone = UILabel()
    private let rightZone = UILabel()
    private let modeLabel = UILabel()
    private let pageLabel = UILabel()
    private let sliderContainer = UIView()
    private let pageSlider = UISlider()
    private var hideWorkItem: DispatchWorkItem?
    private var pageCount = 0
    private var isUpdatingSlider = false
    private var controlsHidden = false
    var onPageSelected: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        configureZone(leftZone, text: "Prev", color: LegacyReaderOverlayView.prevZoneColor)
        configureZone(rightZone, text: "Next", color: LegacyReaderOverlayView.nextZoneColor)
        configurePill(modeLabel, fontSize: 22)
        configurePill(pageLabel, fontSize: 15)
        configureSlider()
        pageLabel.alpha = 0.95

        addSubview(leftZone)
        addSubview(rightZone)
        addSubview(modeLabel)
        addSubview(sliderContainer)
        addSubview(pageLabel)

        NSLayoutConstraint.activate([
            leftZone.topAnchor.constraint(equalTo: topAnchor),
            leftZone.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftZone.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftZone.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.33),

            rightZone.topAnchor.constraint(equalTo: topAnchor),
            rightZone.leadingAnchor.constraint(equalTo: leftZone.trailingAnchor),
            rightZone.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightZone.bottomAnchor.constraint(equalTo: bottomAnchor),

            modeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeLabel.bottomAnchor.constraint(equalTo: pageLabel.topAnchor, constant: -84),
            modeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            modeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            pageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),

            sliderContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            sliderContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            sliderContainer.bottomAnchor.constraint(equalTo: pageLabel.topAnchor, constant: -10),
            sliderContainer.heightAnchor.constraint(equalToConstant: 38),

            pageSlider.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 14),
            pageSlider.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -14),
            pageSlider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor)
        ])
        hideGuide(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !controlsHidden else { return false }
        guard sliderContainer.alpha > 0.01, !sliderContainer.isHidden else { return false }
        let sliderFrame = sliderContainer.frame.insetBy(dx: -8, dy: -12)
        return sliderFrame.contains(point)
    }

    func setControlsHidden(_ hidden: Bool, animated: Bool) {
        controlsHidden = hidden
        if hidden {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        }
        let changes = {
            self.leftZone.alpha = 0
            self.rightZone.alpha = 0
            self.modeLabel.alpha = 0
            self.pageLabel.alpha = hidden || !aidokuLegacyReaderShowsPageNumber() || self.pageLabel.text == nil ? 0 : 0.95
            self.sliderContainer.alpha = hidden || self.pageCount <= 1 ? 0 : 0.92
        }
        if animated {
            UIView.animate(withDuration: 0.18, animations: changes)
        } else {
            changes()
        }
    }

    func updatePage(index: Int?, count: Int) {
        pageCount = count
        updateSlider(index: index, count: count)
        guard count > 0, let index = index else {
            pageLabel.text = nil
            pageLabel.alpha = 0
            return
        }
        pageLabel.text = "\(min(max(index + 1, 1), count)) / \(count)"
        pageLabel.alpha = !controlsHidden && aidokuLegacyReaderShowsPageNumber() ? 0.95 : 0
    }

    func showGuide(modeTitle: String, nextOnLeft: Bool = false) {
        hideWorkItem?.cancel()
        applyZoneDirection(nextOnLeft: nextOnLeft)
        guard !controlsHidden else {
            setControlsHidden(true, animated: false)
            return
        }
        guard aidokuLegacyReaderShowsTapZones() else {
            leftZone.alpha = 0
            rightZone.alpha = 0
            modeLabel.alpha = 0
            pageLabel.alpha = !controlsHidden && aidokuLegacyReaderShowsPageNumber() && pageLabel.text != nil ? 0.95 : 0
            return
        }
        modeLabel.text = modeTitle
        UIView.animate(withDuration: 0.18) {
            self.leftZone.alpha = 1
            self.rightZone.alpha = 1
            self.modeLabel.alpha = 1
            self.pageLabel.alpha = !self.controlsHidden && aidokuLegacyReaderShowsPageNumber() && self.pageLabel.text != nil ? 0.95 : 0
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideGuide(animated: true)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func hideGuide(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let changes = {
            self.leftZone.alpha = 0
            self.rightZone.alpha = 0
            self.modeLabel.alpha = 0
            self.pageLabel.alpha = !self.controlsHidden && aidokuLegacyReaderShowsPageNumber() && self.pageLabel.text != nil ? 0.95 : 0
            self.sliderContainer.alpha = !self.controlsHidden && self.pageCount > 1 ? 0.92 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: changes)
        } else {
            changes()
        }
    }

    private func applyZoneDirection(nextOnLeft: Bool) {
        if nextOnLeft {
            leftZone.text = "Next"
            leftZone.backgroundColor = LegacyReaderOverlayView.nextZoneColor
            rightZone.text = "Prev"
            rightZone.backgroundColor = LegacyReaderOverlayView.prevZoneColor
        } else {
            leftZone.text = "Prev"
            leftZone.backgroundColor = LegacyReaderOverlayView.prevZoneColor
            rightZone.text = "Next"
            rightZone.backgroundColor = LegacyReaderOverlayView.nextZoneColor
        }
    }

    private func configureZone(_ label: UILabel, text: String, color: UIColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = color
        label.text = text
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 28)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    private func configurePill(_ label: UILabel, fontSize: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: fontSize)
        label.layer.cornerRadius = 18
        label.layer.masksToBounds = true
        label.numberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.layoutMargins = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
    }

    private func configureSlider() {
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        sliderContainer.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        sliderContainer.layer.cornerRadius = 10
        sliderContainer.layer.masksToBounds = true
        sliderContainer.alpha = 0

        pageSlider.translatesAutoresizingMaskIntoConstraints = false
        pageSlider.minimumValue = 0
        pageSlider.maximumValue = 0
        pageSlider.isContinuous = false
        pageSlider.minimumTrackTintColor = LegacyPalette.accent
        pageSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.30)
        pageSlider.thumbTintColor = UIColor.white
        pageSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        sliderContainer.addSubview(pageSlider)
    }

    private func updateSlider(index: Int?, count: Int) {
        isUpdatingSlider = true
        pageSlider.minimumValue = 0
        pageSlider.maximumValue = Float(max(count - 1, 0))
        if let index = index {
            pageSlider.value = Float(min(max(index, 0), max(count - 1, 0)))
        } else {
            pageSlider.value = 0
        }
        pageSlider.isEnabled = count > 1
        sliderContainer.alpha = !controlsHidden && count > 1 ? 0.92 : 0
        isUpdatingSlider = false
    }

    @objc private func sliderValueChanged() {
        guard !isUpdatingSlider, pageCount > 1 else { return }
        let pageIndex = min(max(Int(round(pageSlider.value)), 0), pageCount - 1)
        pageSlider.setValue(Float(pageIndex), animated: false)
        pageLabel.text = "\(pageIndex + 1) / \(pageCount)"
        pageLabel.alpha = !controlsHidden && aidokuLegacyReaderShowsPageNumber() ? 0.95 : 0
        onPageSelected?(pageIndex)
    }
}

private final class LegacyZoomableImageView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()

    // Exposed so the reader's single-tap recognizer can `require(toFail:)` it,
    // preventing a double tap from also flipping pages or toggling the bars.
    let doubleTapRecognizer = UITapGestureRecognizer()

    var isZoomed: Bool {
        return zoomScale > minimumZoomScale + 0.01
    }

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.contentScaleFactor = UIScreen.main.scale
            imageView.layer.contentsScale = UIScreen.main.scale
            imageView.layer.magnificationFilter = .nearest
            setZoomScale(1, animated: false)
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = aidokuLegacyIsLowMemoryMode() ? 2 : 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        canCancelContentTouches = true
        panGestureRecognizer.delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.contentScaleFactor = UIScreen.main.scale
        imageView.layer.contentsScale = UIScreen.main.scale
        imageView.layer.magnificationFilter = .nearest
        addSubview(imageView)

        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.addTarget(self, action: #selector(handleDoubleTap(_:)))
        addGestureRecognizer(doubleTapRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard image != nil else { return }
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let targetScale = min(maximumZoomScale, 2)
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            zoom(to: rect, animated: true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImageIfNeeded()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGestureRecognizer {
            return zoomScale > minimumZoomScale
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private func centerImageIfNeeded() {
        let boundsSize = bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) / 2 : 0
        frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) / 2 : 0
        imageView.frame = frame
    }
}

private final class LegacyPageImageCell: UITableViewCell {
    private let pageImageView = LegacyZoomableImageView()
    private let messageStack = UIStackView()
    private let pageLabel = UILabel()
    private let reloadButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var task: URLSessionDataTask?
    private var representedLoadID = UUID()
    private var representedPage: AidokuRunnerLegacyPage?
    private var representedSource: AidokuRunnerLegacySource?
    private var availableSize = CGSize(width: UIScreen.main.bounds.width, height: 420)
    private var fitsViewport = false
    var onHeightChange: (() -> Void)?

    var zoomDoubleTapRecognizer: UIGestureRecognizer { pageImageView.doubleTapRecognizer }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let readerBackground = LegacyReaderBackground.current.color
        backgroundColor = readerBackground
        selectionStyle = .none
        pageImageView.translatesAutoresizingMaskIntoConstraints = false
        pageImageView.contentMode = .scaleAspectFit
        pageImageView.backgroundColor = readerBackground
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textColor = UIColor.white
        pageLabel.textAlignment = .center
        pageLabel.numberOfLines = 0
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.axis = .vertical
        messageStack.alignment = .center
        messageStack.spacing = 12
        configureReloadButton()
        contentView.addSubview(pageImageView)
        contentView.addSubview(messageStack)
        messageStack.addArrangedSubview(pageLabel)
        messageStack.addArrangedSubview(reloadButton)
        heightConstraint = pageImageView.heightAnchor.constraint(equalToConstant: 420)
        leadingConstraint = pageImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = pageImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        NSLayoutConstraint.activate([
            pageImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            leadingConstraint,
            trailingConstraint,
            heightConstraint,
            pageImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            messageStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            messageStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            messageStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            messageStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            pageLabel.widthAnchor.constraint(equalTo: messageStack.widthAnchor),
            reloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            reloadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyReaderBackground(_ color: UIColor) {
        backgroundColor = color
        pageImageView.backgroundColor = color
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseDecodedImage()
        pageLabel.text = nil
        reloadButton.isHidden = true
        representedPage = nil
        representedSource = nil
        pageImageView.isHidden = false
        availableSize = CGSize(width: UIScreen.main.bounds.width, height: 420)
        fitsViewport = false
        heightConstraint.constant = 420
        setSidePadding(0)
        onHeightChange = nil
        applyReaderBackground(LegacyReaderBackground.current.color)
    }

    var currentLoadID: UUID {
        return representedLoadID
    }

    var currentImage: UIImage? {
        return pageImageView.image
    }

    func releaseDecodedImage() {
        task?.cancel()
        task = nil
        representedLoadID = UUID()
        pageImageView.image = nil
    }

    func releaseDecodedImage(ifLoadID loadID: UUID) {
        guard representedLoadID == loadID else { return }
        releaseDecodedImage()
    }

    func configure(
        page: AidokuRunnerLegacyPage,
        source: AidokuRunnerLegacySource,
        availableSize: CGSize,
        fitsViewport: Bool
    ) {
        let loadID = UUID()
        representedLoadID = loadID
        representedPage = page
        representedSource = source
        self.availableSize = availableSize
        self.fitsViewport = fitsViewport
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageImageView.isHidden = false
        pageLabel.text = nil
        reloadButton.isHidden = true
        heightConstraint.constant = fitsViewport ? max(320, availableSize.height) : 420
        switch page.content {
            case .url(let url, let context):
                pageLabel.text = "Loading..."
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source) { [weak self] image in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    if let image = image {
                        self.setImage(image, loadID: loadID)
                    } else {
                        self.showFailure("Image failed to load.", loadID: loadID)
                    }
                }
            case .image(let data):
                setImage(from: data, loadID: loadID)
            case .text(let text):
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = text
            case .zipFile(_, _):
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = "ZIP pages are not supported in the legacy reader yet."
        }
    }

    private func loadLocalImage(url: URL, loadID: UUID) {
        pageLabel.text = "Loading..."
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                return LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure("Downloaded image failed to decode.", loadID: loadID)
                }
            }
        }
    }

    private func load(
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        fallbackRequests: [URLRequest] = [],
        retriesRemaining: Int = 1
    ) {
        task?.cancel()
        task = aidokuLegacyReaderImageSession.dataTask(with: request) { [weak self] data, response, error in
            if source.runner.features.processesPages {
                DispatchQueue.main.async {
                    self?.handleLoadResult(
                        data: data,
                        response: response,
                        error: error,
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        fallbackRequests: fallbackRequests,
                        retriesRemaining: retriesRemaining
                    )
                }
                return
            }
            self?.handleDirectLoadResult(
                data: data,
                response: response,
                error: error,
                request: request,
                context: context,
                source: source,
                loadID: loadID,
                fallbackRequests: fallbackRequests,
                retriesRemaining: retriesRemaining
            )
        }
        task?.resume()
    }

    private func handleDirectLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        fallbackRequests: [URLRequest],
        retriesRemaining: Int
    ) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.async {
                guard self.representedLoadID == loadID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    self.load(
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        fallbackRequests: fallbackRequests,
                        retriesRemaining: retriesRemaining - 1
                    )
                }
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage(data: data, response: httpResponse))
    }

    private func handleLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        fallbackRequests: [URLRequest],
        retriesRemaining: Int
    ) {
        guard representedLoadID == loadID else { return }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.representedLoadID == loadID else { return }
                self.load(
                    request: request,
                    context: context,
                    source: source,
                    loadID: loadID,
                    fallbackRequests: fallbackRequests,
                    retriesRemaining: retriesRemaining - 1
                )
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        let decodeFailureMessage = self.decodeFailureMessage(data: data, response: httpResponse)
        guard source.runner.features.processesPages, let httpResponse = httpResponse else {
            setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
            return
        }
        source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                switch result {
                    case .success(let image?):
                        self.setProcessedImage(image, loadID: loadID)
                    case .success(nil):
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                    case .failure:
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                }
            }
        }
    }

    private func shouldRetry(error: Error?, statusCode: Int?, data: Data?) -> Bool {
        if error != nil || data == nil || data?.isEmpty == true {
            return true
        }
        guard let statusCode = statusCode else { return false }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func showFailure(_ message: String, loadID: UUID) {
        DispatchQueue.main.async {
            guard self.representedLoadID == loadID else { return }
            self.pageImageView.isHidden = true
            self.heightConstraint.constant = 180
            self.pageLabel.text = message
            self.reloadButton.isHidden = false
            self.onHeightChange?()
        }
    }

    private func setProcessedImage(_ image: UIImage, loadID: UUID) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let preparedImage = autoreleasepool {
                aidokuLegacyPrepareReaderImageForDisplay(
                    LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                )
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                self.setImage(preparedImage, loadID: loadID)
            }
        }
    }

    private func setImage(
        from data: Data,
        loadID: UUID,
        failureMessage: String = "Image failed to load."
    ) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool {
                LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure(failureMessage, loadID: loadID)
                }
            }
        }
    }

    private func setSidePadding(_ padding: CGFloat) {
        leadingConstraint.constant = padding
        trailingConstraint.constant = -padding
    }

    private func setImage(_ image: UIImage, loadID: UUID) {
        guard representedLoadID == loadID else { return }
        pageLabel.text = nil
        reloadButton.isHidden = true
        pageImageView.isHidden = false
        pageImageView.image = image
        if fitsViewport {
            setSidePadding(0)
            heightConstraint.constant = max(320, availableSize.height)
        } else {
            // Webtoon-style side padding narrows the strip on wide screens.
            let padding = availableSize.width * aidokuLegacyReaderWebtoonSidePadding()
            setSidePadding(padding)
            let width = max(availableSize.width - 2 * padding, 1)
            let ratio = image.size.height / max(image.size.width, 1)
            let maximumHeight: CGFloat = aidokuLegacyIsLowMemoryMode() ? max(availableSize.height, 768) : 2600
            let targetHeight = min(max(width * ratio, 320), maximumHeight)
            heightConstraint.constant = targetHeight
        }
        onHeightChange?()
    }

    private func configureReloadButton() {
        reloadButton.setTitle("Reload", for: .normal)
        reloadButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        reloadButton.tintColor = UIColor.white
        reloadButton.backgroundColor = LegacyPalette.accent
        reloadButton.layer.cornerRadius = 8
        reloadButton.layer.masksToBounds = true
        reloadButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        reloadButton.isHidden = true
        reloadButton.addTarget(self, action: #selector(reloadCurrentPage), for: .touchUpInside)
    }

    private func loadFallback(
        _ fallbackRequests: [URLRequest],
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID
    ) -> Bool {
        guard let request = fallbackRequests.first else { return false }
        load(
            request: request,
            context: context,
            source: source,
            loadID: loadID,
            fallbackRequests: Array(fallbackRequests.dropFirst()),
            retriesRemaining: 1
        )
        return true
    }

    @objc private func reloadCurrentPage() {
        guard let page = representedPage, let source = representedSource else { return }
        let loadID = UUID()
        representedLoadID = loadID
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageImageView.isHidden = false
        pageLabel.text = "Loading..."
        reloadButton.isHidden = true
        heightConstraint.constant = fitsViewport ? max(320, availableSize.height) : 420
        onHeightChange?()

        switch page.content {
            case .url(let url, let context):
                if url.isFileURL {
                    loadLocalImage(url: url, loadID: loadID)
                    return
                }
                source.runner.getImageRequest(url: url, context: context) { [weak self] result in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    let request: URLRequest
                    switch result {
                        case .success(let imageRequest):
                            request = imageRequest.urlRequest(source: source, fallbackURL: url)
                        case .failure:
                            request = legacyFallbackImageRequest(url: url, source: source)
                    }
                    let reloadRequest = self.reloading(request)
                    let fallbackRequests = legacyFallbackImageRequests(url: url, source: source, excluding: reloadRequest)
                        .map(self.reloading)
                    self.load(
                        request: reloadRequest,
                        context: context,
                        source: source,
                        loadID: loadID,
                        fallbackRequests: fallbackRequests,
                        retriesRemaining: 1
                    )
                }
            case .image(let data):
                setImage(from: data, loadID: loadID)
            case .text(let text):
                pageImageView.isHidden = true
                heightConstraint.constant = 180
                pageLabel.text = text
                onHeightChange?()
            case .zipFile(_, _):
                showFailure("ZIP pages are not supported in the legacy reader yet.", loadID: loadID)
        }
    }

    private func reloading(_ request: URLRequest) -> URLRequest {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func loadFailureMessage(error: Error?, response: HTTPURLResponse?) -> String {
        if let statusCode = response?.statusCode, !(200..<300).contains(statusCode) {
            return httpFailureMessage(statusCode: statusCode, response: response)
        }
        if let error = error {
            return "Image failed to load: \(error.localizedDescription)"
        }
        return "Image failed to load."
    }

    private func httpFailureMessage(statusCode: Int, response: HTTPURLResponse?) -> String {
        if let contentType = headerValue("Content-Type", in: response), !contentType.isEmpty {
            return "Image failed to load. HTTP \(statusCode). \(contentType)"
        }
        return "Image failed to load. HTTP \(statusCode)."
    }

    private func decodeFailureMessage(data: Data, response: HTTPURLResponse?) -> String {
        let contentType = headerValue("Content-Type", in: response)?.lowercased() ?? ""
        if contentType.contains("webp") {
            return "WebP image failed to decode."
        }
        if contentType.contains("avif") {
            return "AVIF image failed to decode."
        }
        if contentType.contains("html") || looksLikeHTML(data) {
            return "Image request returned HTML instead of an image."
        }
        if !contentType.isEmpty && !contentType.contains("image") {
            return "Image request returned \(contentType)."
        }
        return "Image failed to decode."
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse?) -> String? {
        return response?.allHeaderFields.first { header in
            guard let key = header.key as? String else { return false }
            return key.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = Data(data.prefix(128))
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<html") || text.contains("<!doctype")
    }
}

/// Two pages side by side for double-page mode. Each half is independently
/// zoomable; the lower page index is placed per the reader's reading direction
/// by the caller.
private final class LegacyPagedSpreadCell: UICollectionViewCell {
    private let leftView = LegacyZoomableImageView()
    private let rightView = LegacyZoomableImageView()
    private var representedLoadID = UUID()
    private var leftPageIndex: Int?
    private var rightPageIndex: Int?
    var onImageLoaded: ((Int, UIImage) -> Void)?

    var zoomDoubleTapRecognizers: [UIGestureRecognizer] {
        return [leftView.doubleTapRecognizer, rightView.doubleTapRecognizer]
    }

    var currentLoadID: UUID { representedLoadID }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let background = LegacyReaderBackground.current.color
        backgroundColor = background
        contentView.backgroundColor = background
        for view in [leftView, rightView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = background
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            leftView.topAnchor.constraint(equalTo: contentView.topAnchor),
            leftView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leftView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5),
            rightView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rightView.leadingAnchor.constraint(equalTo: leftView.trailingAnchor),
            rightView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyReaderBackground(_ color: UIColor) {
        backgroundColor = color
        contentView.backgroundColor = color
        leftView.backgroundColor = color
        rightView.backgroundColor = color
    }

    func configure(
        leftPage: AidokuRunnerLegacyPage,
        leftPageIndex: Int,
        rightPage: AidokuRunnerLegacyPage,
        rightPageIndex: Int,
        source: AidokuRunnerLegacySource
    ) {
        let loadID = UUID()
        representedLoadID = loadID
        self.leftPageIndex = leftPageIndex
        self.rightPageIndex = rightPageIndex
        applyReaderBackground(LegacyReaderBackground.current.color)
        load(leftPage, pageIndex: leftPageIndex, into: leftView, source: source, loadID: loadID)
        load(rightPage, pageIndex: rightPageIndex, into: rightView, source: source, loadID: loadID)
    }

    private func load(
        _ page: AidokuRunnerLegacyPage,
        pageIndex: Int,
        into imageView: LegacyZoomableImageView,
        source: AidokuRunnerLegacySource,
        loadID: UUID
    ) {
        imageView.image = nil
        switch page.content {
            case .url(let url, let context):
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source) { [weak self, weak imageView] image in
                    guard let self = self, self.representedLoadID == loadID, let imageView = imageView else { return }
                    imageView.image = image
                    if let image = image {
                        self.onImageLoaded?(pageIndex, image)
                    }
                }
            case .image(let data):
                aidokuLegacyImageDecodeQueue.async { [weak self, weak imageView] in
                    let image = autoreleasepool {
                        LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: aidokuLegacyReaderMaxPixelHeight())
                            .map(aidokuLegacyPrepareReaderImageForDisplay)
                    }
                    DispatchQueue.main.async {
                        guard let self = self, self.representedLoadID == loadID, let imageView = imageView else { return }
                        imageView.image = image
                        if let image = image {
                            self.onImageLoaded?(pageIndex, image)
                        }
                    }
                }
            case .text, .zipFile:
                imageView.image = nil
        }
    }

    func releaseDecodedImages() {
        representedLoadID = UUID()
        leftView.image = nil
        rightView.image = nil
    }

    func pageIndex(at location: CGPoint) -> Int? {
        if location.x < bounds.midX {
            return leftPageIndex
        }
        return rightPageIndex
    }

    func currentImage(for pageIndex: Int) -> UIImage? {
        if pageIndex == leftPageIndex {
            return leftView.image
        }
        if pageIndex == rightPageIndex {
            return rightView.image
        }
        return nil
    }

    func releaseDecodedImages(ifLoadID loadID: UUID) {
        guard representedLoadID == loadID else { return }
        releaseDecodedImages()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseDecodedImages()
        leftPageIndex = nil
        rightPageIndex = nil
        onImageLoaded = nil
        applyReaderBackground(LegacyReaderBackground.current.color)
    }
}

private final class LegacyPagedImageCell: UICollectionViewCell {
    private let pageImageView = LegacyZoomableImageView()
    private let messageStack = UIStackView()
    private let pageLabel = UILabel()
    private let reloadButton = UIButton(type: .system)
    private var task: URLSessionDataTask?
    private var representedLoadID = UUID()
    private var representedPage: AidokuRunnerLegacyPage?
    private var representedSource: AidokuRunnerLegacySource?
    var onImageLoaded: ((UIImage) -> Void)?

    var zoomDoubleTapRecognizer: UIGestureRecognizer { pageImageView.doubleTapRecognizer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let readerBackground = LegacyReaderBackground.current.color
        backgroundColor = readerBackground
        contentView.backgroundColor = readerBackground
        pageImageView.translatesAutoresizingMaskIntoConstraints = false
        pageImageView.contentMode = .scaleAspectFit
        pageImageView.backgroundColor = readerBackground
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textColor = UIColor.white
        pageLabel.textAlignment = .center
        pageLabel.numberOfLines = 0
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.axis = .vertical
        messageStack.alignment = .center
        messageStack.spacing = 12
        configureReloadButton()
        contentView.addSubview(pageImageView)
        contentView.addSubview(messageStack)
        messageStack.addArrangedSubview(pageLabel)
        messageStack.addArrangedSubview(reloadButton)
        NSLayoutConstraint.activate([
            pageImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            messageStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            messageStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            messageStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            messageStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 24),
            messageStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            pageLabel.widthAnchor.constraint(equalTo: messageStack.widthAnchor),
            reloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            reloadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyReaderBackground(_ color: UIColor) {
        backgroundColor = color
        contentView.backgroundColor = color
        pageImageView.backgroundColor = color
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseDecodedImage()
        pageLabel.text = nil
        reloadButton.isHidden = true
        representedPage = nil
        representedSource = nil
        onImageLoaded = nil
        pageImageView.isHidden = false
        applyReaderBackground(LegacyReaderBackground.current.color)
    }

    var currentLoadID: UUID {
        return representedLoadID
    }

    var currentImage: UIImage? {
        return pageImageView.image
    }

    func releaseDecodedImage() {
        task?.cancel()
        task = nil
        representedLoadID = UUID()
        pageImageView.image = nil
    }

    func releaseDecodedImage(ifLoadID loadID: UUID) {
        guard representedLoadID == loadID else { return }
        releaseDecodedImage()
    }

    func configure(page: AidokuRunnerLegacyPage, source: AidokuRunnerLegacySource) {
        let loadID = UUID()
        representedLoadID = loadID
        representedPage = page
        representedSource = source
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageImageView.isHidden = false
        pageLabel.text = nil
        reloadButton.isHidden = true
        switch page.content {
            case .url(let url, let context):
                pageLabel.text = "Loading..."
                LegacyReaderImagePipeline.shared.load(url: url, context: context, source: source) { [weak self] image in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    if let image = image {
                        self.setImage(image, loadID: loadID)
                    } else {
                        self.showFailure("Image failed to load.", loadID: loadID)
                    }
                }
            case .image(let data):
                setImage(from: data, loadID: loadID)
            case .text(let text):
                pageImageView.isHidden = true
                pageLabel.text = text
            case .zipFile(_, _):
                pageImageView.isHidden = true
                pageLabel.text = "ZIP pages are not supported in the legacy reader yet."
        }
    }

    private func loadLocalImage(url: URL, loadID: UUID) {
        pageLabel.text = "Loading..."
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                return LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure("Downloaded image failed to decode.", loadID: loadID)
                }
            }
        }
    }

    private func load(
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        fallbackRequests: [URLRequest] = [],
        retriesRemaining: Int = 1
    ) {
        task?.cancel()
        task = aidokuLegacyReaderImageSession.dataTask(with: request) { [weak self] data, response, error in
            if source.runner.features.processesPages {
                DispatchQueue.main.async {
                    self?.handleLoadResult(
                        data: data,
                        response: response,
                        error: error,
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        fallbackRequests: fallbackRequests,
                        retriesRemaining: retriesRemaining
                    )
                }
                return
            }
            self?.handleDirectLoadResult(
                data: data,
                response: response,
                error: error,
                request: request,
                context: context,
                source: source,
                loadID: loadID,
                fallbackRequests: fallbackRequests,
                retriesRemaining: retriesRemaining
            )
        }
        task?.resume()
    }

    private func handleDirectLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        fallbackRequests: [URLRequest],
        retriesRemaining: Int
    ) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.async {
                guard self.representedLoadID == loadID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    self.load(
                        request: request,
                        context: context,
                        source: source,
                        loadID: loadID,
                        fallbackRequests: fallbackRequests,
                        retriesRemaining: retriesRemaining - 1
                    )
                }
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage(data: data, response: httpResponse))
    }

    private func handleLoadResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        request: URLRequest,
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID,
        fallbackRequests: [URLRequest],
        retriesRemaining: Int
    ) {
        guard representedLoadID == loadID else { return }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        if shouldRetry(error: error, statusCode: statusCode, data: data), retriesRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.representedLoadID == loadID else { return }
                self.load(
                    request: request,
                    context: context,
                    source: source,
                    loadID: loadID,
                    fallbackRequests: fallbackRequests,
                    retriesRemaining: retriesRemaining - 1
                )
            }
            return
        }
        guard let data = data, !data.isEmpty else {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(loadFailureMessage(error: error, response: httpResponse), loadID: loadID)
            return
        }
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            if loadFallback(fallbackRequests, context: context, source: source, loadID: loadID) {
                return
            }
            showFailure(httpFailureMessage(statusCode: statusCode, response: httpResponse), loadID: loadID)
            return
        }
        let decodeFailureMessage = self.decodeFailureMessage(data: data, response: httpResponse)
        guard source.runner.features.processesPages, let httpResponse = httpResponse else {
            setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
            return
        }
        source.runner.processPageImage(data: data, response: httpResponse, request: request, context: context) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                switch result {
                    case .success(let image?):
                        self.setProcessedImage(image, loadID: loadID)
                    case .success(nil):
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                    case .failure:
                        self.setImage(from: data, loadID: loadID, failureMessage: decodeFailureMessage)
                }
            }
        }
    }

    private func shouldRetry(error: Error?, statusCode: Int?, data: Data?) -> Bool {
        if error != nil || data == nil || data?.isEmpty == true {
            return true
        }
        guard let statusCode = statusCode else { return false }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func showFailure(_ message: String, loadID: UUID) {
        DispatchQueue.main.async {
            guard self.representedLoadID == loadID else { return }
            self.pageImageView.isHidden = true
            self.pageLabel.text = message
            self.reloadButton.isHidden = false
        }
    }

    private func setProcessedImage(_ image: UIImage, loadID: UUID) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let preparedImage = autoreleasepool {
                aidokuLegacyPrepareReaderImageForDisplay(
                    LegacyImageLoader.shared.preparedImage(image, maxPixelHeight: maxHeight)
                )
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                self.setImage(preparedImage, loadID: loadID)
            }
        }
    }

    private func setImage(
        from data: Data,
        loadID: UUID,
        failureMessage: String = "Image failed to load."
    ) {
        aidokuLegacyImageDecodeQueue.async { [weak self] in
            let maxHeight = aidokuLegacyReaderMaxPixelHeight()
            let image = autoreleasepool {
                LegacyImageLoader.shared.makeImage(from: data, maxPixelHeight: maxHeight)
                    .map(aidokuLegacyPrepareReaderImageForDisplay)
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedLoadID == loadID else { return }
                if let image = image {
                    self.setImage(image, loadID: loadID)
                } else {
                    self.showFailure(failureMessage, loadID: loadID)
                }
            }
        }
    }

    private func setImage(_ image: UIImage, loadID: UUID) {
        guard representedLoadID == loadID else { return }
        pageLabel.text = nil
        reloadButton.isHidden = true
        pageImageView.isHidden = false
        pageImageView.image = image
        onImageLoaded?(image)
    }

    private func configureReloadButton() {
        reloadButton.setTitle("Reload", for: .normal)
        reloadButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        reloadButton.tintColor = UIColor.white
        reloadButton.backgroundColor = LegacyPalette.accent
        reloadButton.layer.cornerRadius = 8
        reloadButton.layer.masksToBounds = true
        reloadButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        reloadButton.isHidden = true
        reloadButton.addTarget(self, action: #selector(reloadCurrentPage), for: .touchUpInside)
    }

    private func loadFallback(
        _ fallbackRequests: [URLRequest],
        context: [String: String]?,
        source: AidokuRunnerLegacySource,
        loadID: UUID
    ) -> Bool {
        guard let request = fallbackRequests.first else { return false }
        load(
            request: request,
            context: context,
            source: source,
            loadID: loadID,
            fallbackRequests: Array(fallbackRequests.dropFirst()),
            retriesRemaining: 1
        )
        return true
    }

    @objc private func reloadCurrentPage() {
        guard let page = representedPage, let source = representedSource else { return }
        let loadID = UUID()
        representedLoadID = loadID
        task?.cancel()
        task = nil
        pageImageView.image = nil
        pageImageView.isHidden = false
        pageLabel.text = "Loading..."
        reloadButton.isHidden = true

        switch page.content {
            case .url(let url, let context):
                if url.isFileURL {
                    loadLocalImage(url: url, loadID: loadID)
                    return
                }
                source.runner.getImageRequest(url: url, context: context) { [weak self] result in
                    guard let self = self, self.representedLoadID == loadID else { return }
                    let request: URLRequest
                    switch result {
                        case .success(let imageRequest):
                            request = imageRequest.urlRequest(source: source, fallbackURL: url)
                        case .failure:
                            request = legacyFallbackImageRequest(url: url, source: source)
                    }
                    let reloadRequest = self.reloading(request)
                    let fallbackRequests = legacyFallbackImageRequests(url: url, source: source, excluding: reloadRequest)
                        .map(self.reloading)
                    self.load(
                        request: reloadRequest,
                        context: context,
                        source: source,
                        loadID: loadID,
                        fallbackRequests: fallbackRequests,
                        retriesRemaining: 1
                    )
                }
            case .image(let data):
                setImage(from: data, loadID: loadID)
            case .text(let text):
                pageImageView.isHidden = true
                pageLabel.text = text
            case .zipFile(_, _):
                showFailure("ZIP pages are not supported in the legacy reader yet.", loadID: loadID)
        }
    }

    private func reloading(_ request: URLRequest) -> URLRequest {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func loadFailureMessage(error: Error?, response: HTTPURLResponse?) -> String {
        if let statusCode = response?.statusCode, !(200..<300).contains(statusCode) {
            return httpFailureMessage(statusCode: statusCode, response: response)
        }
        if let error = error {
            return "Image failed to load: \(error.localizedDescription)"
        }
        return "Image failed to load."
    }

    private func httpFailureMessage(statusCode: Int, response: HTTPURLResponse?) -> String {
        if let contentType = headerValue("Content-Type", in: response), !contentType.isEmpty {
            return "Image failed to load. HTTP \(statusCode). \(contentType)"
        }
        return "Image failed to load. HTTP \(statusCode)."
    }

    private func decodeFailureMessage(data: Data, response: HTTPURLResponse?) -> String {
        let contentType = headerValue("Content-Type", in: response)?.lowercased() ?? ""
        if contentType.contains("webp") {
            return "WebP image failed to decode."
        }
        if contentType.contains("avif") {
            return "AVIF image failed to decode."
        }
        if contentType.contains("html") || looksLikeHTML(data) {
            return "Image request returned HTML instead of an image."
        }
        if !contentType.isEmpty && !contentType.contains("image") {
            return "Image request returned \(contentType)."
        }
        return "Image failed to decode."
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse?) -> String? {
        return response?.allHeaderFields.first { header in
            guard let key = header.key as? String else { return false }
            return key.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = Data(data.prefix(128))
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<html") || text.contains("<!doctype")
    }
}

private extension AidokuRunnerLegacyChapter {
    var normalizedLanguage: String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return nil
        }
        return language.lowercased()
    }

    var legacyFormattedTitle: String {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefix: [String] = []
        if let volumeNumber = volumeNumber {
            prefix.append("Vol. \(Self.format(number: volumeNumber))")
        }
        if let chapterNumber = chapterNumber {
            prefix.append("Ch. \(Self.format(number: chapterNumber))")
        }
        if prefix.isEmpty {
            if let cleanTitle = cleanTitle, !cleanTitle.isEmpty {
                return cleanTitle
            }
            return "Chapter \(key)"
        }
        if let cleanTitle = cleanTitle, !cleanTitle.isEmpty {
            return "\(prefix.joined(separator: " ")) - \(cleanTitle)"
        }
        return prefix.joined(separator: " ")
    }

    func legacyFormattedSubtitle(sourceKey: String) -> String? {
        var components: [String] = []
        if locked {
            components.append("Unavailable")
        }
        if let dateUploaded = dateUploaded {
            components.append(LegacyChapterFormatters.dateFormatter.string(from: dateUploaded))
        }
        if let scanlators = scanlators, !scanlators.isEmpty {
            components.append(scanlators.joined(separator: ", "))
        }
        if
            let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
            !language.isEmpty,
            shouldShowLanguage(sourceKey: sourceKey)
        {
            components.append(language.uppercased())
        }
        return components.isEmpty ? nil : components.joined(separator: " - ")
    }

    private func shouldShowLanguage(sourceKey: String) -> Bool {
        let selectedLanguages = UserDefaults.standard.stringArray(forKey: "\(sourceKey).languages") ?? []
        return selectedLanguages.count > 1
    }

    private static func format(number: Float) -> String {
        return LegacyChapterFormatters.numberFormatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}

private enum LegacyChapterFormatters {
    static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private extension AidokuRunnerLegacyManga {
    func coverURL(relativeTo baseURL: URL?) -> URL? {
        return coverURLCandidates(relativeTo: baseURL).first
    }

    func coverURLCandidates(relativeTo baseURL: URL?) -> [URL] {
        guard let cover = cover?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty else {
            return []
        }
        var urls: [URL] = []
        for candidate in Self.urlCandidates(from: cover) {
            if let url = URL(string: candidate), url.scheme != nil {
                Self.appendURL(url, to: &urls)
            }
        }
        if let baseURL = baseURL {
            for candidate in Self.urlCandidates(from: cover) {
                if let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL {
                    Self.appendURL(url, to: &urls)
                }
            }
        }
        for candidate in Self.urlCandidates(from: cover) {
            if let url = URL(string: candidate) {
                Self.appendURL(url, to: &urls)
            }
        }
        let initialURLs = urls
        for url in initialURLs {
            for fallbackURL in legacyMangaDexCoverFallbackURLs(from: url) {
                Self.appendURL(fallbackURL, to: &urls)
            }
        }
        for url in Self.inferredMangaDexCoverURLs(from: cover, baseURL: baseURL, mangaKey: key) {
            Self.appendURL(url, to: &urls)
        }
        return urls
    }

    private static func urlCandidates(from value: String) -> [String] {
        var candidates: [String] = []
        let normalized = value.replacingOccurrences(of: "\\/", with: "/")
        appendURLCandidate(normalized, to: &candidates)
        appendURLCandidate(normalized.replacingOccurrences(of: " ", with: "%20"), to: &candidates)
        if let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            appendURLCandidate(encoded, to: &candidates)
        }
        return candidates
    }

    private static func appendURLCandidate(_ value: String, to candidates: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendUnique(trimmed, to: &candidates)
        if trimmed.hasPrefix("//") {
            appendUnique("https:" + trimmed, to: &candidates)
        } else if looksLikeHostPath(trimmed) {
            appendUnique("https://" + trimmed, to: &candidates)
        }
    }

    private static func looksLikeHostPath(_ value: String) -> Bool {
        guard !value.contains("://"), !value.hasPrefix("/"), !value.contains(" ") else {
            return false
        }
        let host = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        return host.contains(".")
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private static func appendURL(_ url: URL, to urls: inout [URL]) {
        guard !urls.contains(url) else { return }
        urls.append(url)
    }

    private static func inferredMangaDexCoverURLs(from cover: String, baseURL: URL?, mangaKey: String) -> [URL] {
        guard looksLikeMangaDex(baseURL: baseURL, mangaKey: mangaKey) else { return [] }
        let normalized = cover.replacingOccurrences(of: "\\/", with: "/")
        let fileName = (normalized as NSString).lastPathComponent
        guard fileName.contains(".") else { return [] }

        var urls: [URL] = []
        for fileName in legacyMangaDexCoverFileNameCandidates(from: fileName) {
            guard let url = URL(string: "https://uploads.mangadex.org/covers/\(mangaKey)/\(fileName)") else { continue }
            appendURL(url, to: &urls)
        }
        return urls
    }

    private static func looksLikeMangaDex(baseURL: URL?, mangaKey: String) -> Bool {
        if baseURL?.host?.lowercased().contains("mangadex") == true {
            return true
        }
        return mangaKey.range(
            of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}

private struct LegacyWebLoginResult {
    let cookies: [String: String]
    let localStorage: [String: String]
}

private final class LegacySourceWebViewController: UIViewController, WKNavigationDelegate {
    private let initialURL: URL
    private let sourceTitle: String
    private let localStorageKeys: [String]
    private let loginCompletion: ((LegacyWebLoginResult) -> Void)?
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)

    init(
        url: URL,
        title: String,
        localStorageKeys: [String] = [],
        loginCompletion: ((LegacyWebLoginResult) -> Void)? = nil
    ) {
        self.initialURL = url
        self.sourceTitle = title
        self.localStorageKeys = localStorageKeys
        self.loginCompletion = loginCompletion
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // iOS 12's stock WebKit reports an old Safari user agent that some sites
        // (e.g. MangaDex) reject with "400: unsupported browser". Spoof a current
        // mobile Safari UA so those pages load.
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var rightItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(openInSafari)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadPage))
        ]
        if loginCompletion != nil {
            rightItems.insert(UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(finishLogin)), at: 0)
        }
        navigationItem.rightBarButtonItems = rightItems
        progressView.frame = CGRect(x: 0, y: 0, width: 120, height: 2)
        updateToolbar(animated: false)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        webView.load(URLRequest(url: initialURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == #keyPath(WKWebView.estimatedProgress) else { return }
        progressView.progress = Float(webView.estimatedProgress)
        progressView.isHidden = webView.estimatedProgress >= 1
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        progressView.isHidden = false
        updateTitle()
        updateToolbar(animated: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressView.isHidden = true
        updateTitle()
        updateToolbar(animated: true)
    }

    private func updateToolbar(animated: Bool) {
        let back = UIBarButtonItem(title: "Back", style: .plain, target: self, action: #selector(goBack))
        back.isEnabled = webView?.canGoBack ?? false

        let forward = UIBarButtonItem(title: "Forward", style: .plain, target: self, action: #selector(goForward))
        forward.isEnabled = webView?.canGoForward ?? false

        setToolbarItems(
            [
                back,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(customView: progressView),
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                forward
            ],
            animated: animated
        )
    }

    private func updateTitle() {
        title = webView.title?.isEmpty == false ? webView.title : sourceTitle
    }

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openInSafari() {
        guard let url = webView.url ?? URL(string: initialURL.absoluteString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @objc private func finishLogin() {
        collectLocalStorage { [weak self] localStorage in
            guard let self = self else { return }
            self.collectCookies { cookies in
                self.loginCompletion?(LegacyWebLoginResult(cookies: cookies, localStorage: localStorage))
            }
        }
    }

    private func collectLocalStorage(completion: @escaping ([String: String]) -> Void) {
        guard !localStorageKeys.isEmpty else {
            completion([:])
            return
        }
        guard
            let keysData = try? JSONSerialization.data(withJSONObject: localStorageKeys, options: []),
            let keysJSON = String(data: keysData, encoding: .utf8)
        else {
            completion([:])
            return
        }
        let script = """
        (function() {
          var result = {};
          \(keysJSON).forEach(function(key) {
            var value = window.localStorage.getItem(key);
            if (value !== null) { result[key] = value; }
          });
          return result;
        })();
        """
        webView.evaluateJavaScript(script) { value, _ in
            let dictionary = value as? [String: Any] ?? [:]
            let strings = dictionary.reduce(into: [String: String]()) { result, item in
                if let value = item.value as? String {
                    result[item.key] = value
                }
            }
            completion(strings)
        }
    }

    private func collectCookies(completion: @escaping ([String: String]) -> Void) {
        var cookies = cookieValues(from: HTTPCookieStorage.shared.cookies ?? [])
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] webCookies in
            guard let self = self else { return }
            for cookie in webCookies where self.isRelevant(cookie: cookie) {
                HTTPCookieStorage.shared.setCookie(cookie)
                cookies[cookie.name] = cookie.value
            }
            DispatchQueue.main.async {
                completion(cookies)
            }
        }
    }

    private func cookieValues(from cookies: [HTTPCookie]) -> [String: String] {
        return cookies.reduce(into: [String: String]()) { result, cookie in
            guard isRelevant(cookie: cookie) else { return }
            result[cookie.name] = cookie.value
        }
    }

    private func isRelevant(cookie: HTTPCookie) -> Bool {
        guard let host = initialURL.host?.lowercased(), !host.isEmpty else { return true }
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain == host || domain.hasSuffix(".\(host)") || host.hasSuffix(".\(domain)")
    }
}

// Searches a tracker for candidates and reports the chosen result back to the caller.
// Used by the manga detail screen to link a manga to an AniList / MyAnimeList record.
final class LegacyTrackerSearchViewController: UITableViewController, UISearchResultsUpdating {
    private let trackerId: LegacyTrackerId
    private let onPick: (LegacyTrackSearchResult) -> Void
    private let searchController = UISearchController(searchResultsController: nil)

    private var results: [LegacyTrackSearchResult] = []
    private var isLoading = false
    private var pendingSearch: DispatchWorkItem?
    private var currentQuery: String

    init(
        trackerId: LegacyTrackerId,
        initialQuery: String,
        onPick: @escaping (LegacyTrackSearchResult) -> Void
    ) {
        self.trackerId = trackerId
        self.currentQuery = initialQuery
        self.onPick = onPick
        super.init(style: .plain)
        title = "Link to \(trackerId.displayName)"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search \(trackerId.displayName)"
        searchController.searchBar.text = currentQuery
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        performSearch(query: currentQuery)
    }

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            tableView.reloadData()
            return
        }
        isLoading = true
        LegacyTrackerManager.shared.search(trackerId: trackerId, title: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                    case .success(let items):
                        self.results = items
                        self.tableView.reloadData()
                    case .failure(let error):
                        self.results = []
                        self.tableView.reloadData()
                        let alert = UIAlertController(title: "Search Failed", message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true)
                }
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(query: text)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "Cell")
        let item = results[indexPath.row]
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.totalChapters > 0 ? "\(item.totalChapters) chapters" : "Unknown length"
        cell.accessoryType = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = results[indexPath.row]
        onPick(item)
        navigationController?.popViewController(animated: true)
    }
}
