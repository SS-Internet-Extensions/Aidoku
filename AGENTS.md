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
- AI-authored commits must include a `Co-Authored-By:` trailer for the agent model.
