# iOS 12 Port Notes

## Requirement

First-generation iPad Air devices top out at iOS 12.x, so supporting that hardware requires an app build that can install and run on iOS 12.

## Current State

The current iOS app target is set to iOS 15.0. Lowering `IPHONEOS_DEPLOYMENT_TARGET` to 12.0 is not enough, because the source tree relies on APIs and frameworks introduced after iOS 12:

- SwiftUI, used throughout `iOS/New/` and some shared view wrappers, requires iOS 13+.
- Combine and `ObservableObject` require iOS 13+.
- Swift concurrency (`async`, `await`, `Task`, actors, task groups) is used across managers, downloads, trackers, sources, and tests. Swift concurrency back deployment does not cover iOS 12.
- Modern UIKit APIs such as diffable data sources, compositional layouts, context menus, `UIAction`, SF Symbols, and dynamic system colors require iOS 13+ or newer.

## Native Port Strategy

Use the separate `AidokuLegacy (iOS 12)` target instead of weakening the current target:

1. Keep `AidokuLegacy (iOS 12)` at `IPHONEOS_DEPLOYMENT_TARGET = 12.0`.
2. Build the legacy UI with UIKit only. Do not include SwiftUI or Combine files.
3. Replace async APIs with callbacks, `OperationQueue`, delegates, or completion handlers.
4. Replace modern collection APIs with `UICollectionViewDataSource` and flow layouts.
5. Replace SF Symbols with bundled PDF/vector assets.
6. Gate or remove iOS 13+ features: live text, modern sheet behavior, context menus, background processing, and SwiftUI settings screens.
7. Keep iPad Air 1 defaults lightweight: downsample reader images, preload fewer pages, disable parallel downloads, and avoid expensive transitions.

This is a substantial compatibility fork, not a project-setting change.

The initial target is a minimal UIKit shell under `iOSLegacy/`. It proves the iOS 12 target can launch independently while feature code is ported incrementally.

The shell also includes an iOS 12-safe source catalog client for `https://aidoku-community.github.io/sources/index.min.json`. It can list community sources, resolve icon/package URLs, download `.aix` packages, and install them through the local `AidokuRunnerLegacy` facade.

`AidokuRunnerLegacy` is intentionally small and callback-based. It validates `source.json` and `main.wasm`, installs packages with `ZIPFoundation`, and exposes a backend factory for search/listing/details/chapter/page execution. The default backend does not run WASM yet; connect a Swift 5/Xcode 15.4/iOS 12-compatible runtime behind `AidokuRunnerLegacyBackendFactory` before expecting sources to execute.

## CI

GitHub Actions builds the shell target in `.github/workflows/legacy-ios12.yml` with Xcode 15.4 on `macos-14`:

```sh
xcodebuild -project iOSLegacy/AidokuLegacy.xcodeproj -scheme "AidokuLegacy (iOS 12)" -configuration Debug -destination 'generic/platform=iOS' build
```

The standalone `iOSLegacy/AidokuLegacy.xcodeproj` exists because current Xcode releases no longer support an iOS 12 deployment target, while the main project file uses newer Xcode project objects. Keep it minimal and Xcode 15-compatible until the legacy feature set is fully ported.

The standalone project pins `ZIPFoundation` exactly at `0.9.19`, which supports iOS 9+ and is compatible with the legacy package installer.

As of June 2026, GitHub's `macos-14` image still provides Xcode 15.4, but that runner image is scheduled for deprecation beginning July 6, 2026 and full removal from hosted support on November 2, 2026. If hosted `macos-14` disappears, keep this workflow on a self-hosted macOS 14 runner with Xcode 15.4.

## Flutter Port Feasibility

Current Flutter stable does not solve the iOS 12 requirement: Flutter's supported platform table lists iOS 13+ as supported and iOS 12 and earlier as unsupported.

A Flutter rewrite is still possible only if one of these constraints is accepted:

- Target iOS 13+ with current Flutter. This will not run on iPad Air 1.
- Pin an old Flutter SDK that still builds for iOS 12, then also pin Dart/packages/plugins to compatible versions. This is unsupported and high-maintenance.

## Recommendation

For iPad Air 1 support, prefer a native `AidokuLegacy` target with a reduced feature set. Reuse portable model/parser/storage code only after removing Swift concurrency from the reused surface. Do not replace the current app target with iOS 12 settings until the legacy target compiles independently.
