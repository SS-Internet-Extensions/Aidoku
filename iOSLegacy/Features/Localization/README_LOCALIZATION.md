# Legacy Localization

Localization infrastructure for the **AidokuLegacy (iOS 12)** UIKit target.

## Files

- `LegacyLocalization.swift` — the `LegacyString(_:_:)` helper and the
  `String.legacyLocalized` convenience accessor.
- `en.lproj/Localizable.strings` — the English string table (starter catalog).

## Usage

```swift
title = LegacyString("tab.library")     // -> "Library"
label.text = "settings.dark_theme".legacyLocalized  // -> "Dark Theme"
```

If a key is missing from the table, the helper returns the key itself, so the
app stays usable while strings are being migrated.

## Key convention

Keys are `dot.separated` `snake_case`, grouped by screen:

```
"tab.library"            = "Library";
"library.empty.title"    = "No manga in Library.";
"repo.invalid.message"   = "Enter a valid source repository URL.";
"button.cancel"          = "Cancel";
```

Format-string values use `%@` positional placeholders, e.g.
`"reader.unavailable.message" = "%@ is unavailable from this source.";`
Resolve them with `String(format: LegacyString("reader.unavailable.message"), name)`.

Every line in a `.strings` file must be `"key" = "value";` and comments use
`/* ... */`. Files are UTF-8.

## Adding a locale

1. Create `<locale>.lproj/Localizable.strings` next to `en.lproj`
   (e.g. `fr.lproj/Localizable.strings`, `ja.lproj/Localizable.strings`).
2. Copy the keys from `en.lproj/Localizable.strings` and translate the values.
   Keep the keys identical across locales.
3. Add the new `.lproj` folder to the app target's **Copy Bundle Resources**
   build phase in the Xcode project.

## Migration

`LegacyRootViewController.swift` still hard-codes English literals. Migrate them
incrementally, replacing each literal with a `LegacyString(...)` call, e.g.:

```swift
// before
title = "Library"
// after
title = LegacyString("tab.library")
```

Do not bulk-rewrite the whole file at once — adopt the helper screen by screen
and verify each change builds against the iOS 12 toolchain.
