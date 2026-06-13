# Repository Guidelines

## Project Structure & Module Organization
- `Aidoku.xcodeproj` is the canonical Xcode project. Shared schemes live in `Aidoku.xcodeproj/xcshareddata/xcschemes/`.
- `Shared/` contains cross-platform Swift code, Core Data models, source/tracker logic, WASM integration, localizations, and asset catalogs.
- `iOS/` contains iOS app entry points plus UIKit/SwiftUI views. Newer screens are under `iOS/New/`; legacy screens are under `iOS/Old UI/` and `iOS/UI/`.
- `macOS/` contains the macOS app target and platform-specific views/configuration.
- `AidokuTests/` contains XCTest cases such as `LocalFileNameParserTests.swift` and `TrackerSyncTests.swift`.

## Build, Test, and Development Commands
| Task | Command |
|------|---------|
| Open project | `open Aidoku.xcodeproj` |
| Build iOS | `xcodebuild -project Aidoku.xcodeproj -scheme "Aidoku (iOS)" -destination 'platform=iOS Simulator,name=iPhone 16' build` |
| Test iOS | `xcodebuild test -project Aidoku.xcodeproj -scheme "Aidoku (iOS)" -destination 'platform=iOS Simulator,name=iPhone 16'` |
| Build iOS 12 legacy | `xcodebuild -project iOSLegacy/AidokuLegacy.xcodeproj -scheme "AidokuLegacy (iOS 12)" -configuration Release -destination 'generic/platform=iOS' build` |
| Build macOS | `xcodebuild -project Aidoku.xcodeproj -scheme "Aidoku (macOS)" build` |
| Lint Swift | `swiftlint lint` |

- Replace the simulator name with an installed local simulator when needed.
- Swift Package Manager dependencies are resolved through Xcode; keep `Aidoku.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` in sync when dependencies change.

## Coding Style & Naming Conventions
- Follow `.swiftlint.yml`; CI runs SwiftLint on pull requests touching Swift files.
- Use Swift 5 conventions: types in `UpperCamelCase`, methods/properties in `lowerCamelCase`, and four-space indentation.
- Prefer existing view/model patterns in the surrounding directory before adding new abstractions.
- Add localizable user-facing strings under `Shared/Localization/<locale>.lproj/Localizable.strings`.

## Testing Guidelines
- Use XCTest in `AidokuTests/`; name test files `FeatureTests.swift` and test methods with `test...`.
- Add focused tests for parser, backup, tracker, Core Data, and migration changes where behavior can regress silently.
- For a single test, use `-only-testing:AidokuTests/ClassName/testMethod` with the `xcodebuild test` command above.

## Commit & Pull Request Guidelines
- Recent history uses short conventional prefixes, especially `fix:` and `chore:`. Keep subjects concise and behavior-focused.
- Pull requests should describe the change, list manual or automated verification, link relevant issues, and include screenshots or recordings for UI changes.
- Contributors should coordinate larger changes in the Discord app development channel and must sign the project CLA referenced in `README.md`.

## Agent-Specific Instructions
- Prefix shell commands with `rtk`, for example `rtk git status` or `rtk swiftlint lint`.
- For iOS 12 work, read `docs/iOS12_PORT.md`, `docs/SOURCES_IOS12.md`, `docs/iOS12_FEATURE_PARITY.md`, and `docs/TASKS.md` before editing.
- After feature, build, or bug-fix work, update `docs/TASKS.md` and `docs/WORK_TRACKING.md` when status, risks, or verification changes.
- Commits made for Hai should use the configured author identity, be GPG-signed with `rtk git commit -S`, and only use Hai as author/committer/co-author.
- After every push, use the `gh` CLI to read the triggered GitHub Actions build log (e.g. `gh run watch <id> -R SS-Internet-Extensions/Aidoku --exit-status`, or `gh run view <id> --log-failed`). If a build fails, diagnose and fix the cause, then push and re-check, repeating until the build succeeds. Pushes go to the `ss-internet` remote (`SS-Internet-Extensions/Aidoku`); `origin` (`Aidoku/Aidoku`) is upstream and not pushable.

```text
Co-Authored-By: Hai Tran <hoanghaivn0406@gmail.com>
```
