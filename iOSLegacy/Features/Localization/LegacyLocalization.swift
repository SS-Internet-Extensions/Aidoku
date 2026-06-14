//
//  LegacyLocalization.swift
//  AidokuLegacy (iOS 12)
//
//  Lightweight localization helper for the legacy UIKit target.
//  Resolves keys against Localizable.strings in the main bundle.
//  See Features/Localization/README_LOCALIZATION.md for conventions.
//

import Foundation

/// The table (strings file base name) that holds legacy UI strings.
private let legacyLocalizationTable = "Localizable"

/// Look up a localized string for the legacy UI.
///
/// Resolves `key` against `Localizable.strings` in the main bundle.
/// If the key is missing the key itself is returned, which keeps the
/// UI readable while strings are migrated incrementally.
///
/// - Parameters:
///   - key: A dot.separated snake_case key, e.g. `"tab.library"`.
///   - comment: Optional translator note (unused at runtime).
/// - Returns: The localized value, or `key` if no entry exists.
func LegacyString(_ key: String, _ comment: String = "") -> String {
    NSLocalizedString(
        key,
        tableName: legacyLocalizationTable,
        bundle: Bundle.main,
        value: key,
        comment: comment
    )
}

extension String {
    /// Localized value of this string treated as a legacy string key.
    ///
    /// Equivalent to `LegacyString(self)`. Returns `self` if the key
    /// is not present in `Localizable.strings`.
    var legacyLocalized: String {
        LegacyString(self)
    }
}
