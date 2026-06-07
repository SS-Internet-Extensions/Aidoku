# iOS 12 Source Compatibility

Aidoku Community Sources are distributed through:

```text
https://aidoku-community.github.io/sources/index.min.json
```

The index is a JSON object with `name`, optional `feedbackURL`, and `sources`. Each source includes metadata such as `id`, `name`, `version`, `iconURL`, `downloadURL`, `languages`, `contentRating`, `baseURL`, and optional app-version gates.

`iOSLegacy/LegacySourceCatalog.swift` keeps this format compatible with iOS 12 by avoiding Swift concurrency. It supports:

- loading the community index with `URLSessionDataTask`
- decoding modern and older flat source-list formats
- resolving relative `icons/...` and `sources/...aix` URLs
- downloading `.aix` packages into `Application Support/LegacySources`
- searching by source name, id, alternate names, and language

`iOSLegacy/AidokuRunnerLegacy*.swift` adds the personal-use legacy runner boundary for installed packages. The current implementation:

- unzips `.aix` packages with `ZIPFoundation`
- handles package payloads with or without a `Payload/` wrapper
- validates `source.json` and `main.wasm`
- installs sources into `Application Support/AidokuRunnerLegacy/<source-id>`
- loads source metadata, static listings, base URLs, icons, and content ratings
- exposes callback-based search, listing, details, chapters, pages, and image-request APIs

The UI now downloads community `.aix` packages and installs them through `AidokuRunnerLegacyPackageInstaller`. It does not execute WASM yet: the default backend returns `backendUnavailable` until a Swift 5/iOS 12-compatible WASM backend is connected through `AidokuRunnerLegacyBackendFactory`.

Keep catalog, install, and backend execution separated so GitHub Actions can continue to prove the iOS 12 compatibility baseline while the runtime is backfilled.

## Aidoku Organization Findings

The relevant upstream repositories in `https://github.com/Aidoku` are:

- `Aidoku/Aidoku`: the current Swift app. Its main iOS target is iOS 15+ and uses the modern source manager.
- `Aidoku/AidokuRunner`: the current Swift source runtime. `Package.swift` uses Swift tools 6.0, `swiftLanguageModes: [.v6]`, and `platforms: [.macOS(.v12), .iOS(.v15)]`.
- `Aidoku/aidoku-rs`: the Rust source API and source-development toolchain used to build `.aix` packages.
- `Aidoku/aidoku-as` and `Aidoku/aidoku-cli`: older source tooling, both archived.

This means community `.aix` packages are the right package format for `AidokuLegacy`, but the current runtime cannot be linked directly into an iOS 12/Xcode 15.4 target. A real iOS 12 source runner needs either:

- the local `AidokuRunnerLegacy` facade plus a Swift 5.9/Xcode 15.4, iOS 12-compatible WASM backend, or
- a native copy of the older in-app `Shared/Wasm` + `Shared/Sources/Source.swift` runtime adapted to the current `.aix` API surface.

Do not copy `AidokuRunner` code into this project without resolving its source-available license terms. Its README states it is not GPLv3 and derivatives should not be redistributed without permission.
