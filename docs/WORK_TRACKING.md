# Work Tracking

Use this file to record the state of ongoing AidokuLegacy work after each meaningful change. Keep entries short and link to detailed docs instead of duplicating them.

## Current Focus

- iOS 12 legacy target: maintain installable builds for iPad Air 1-class devices.
- Source execution: keep `AidokuRunnerLegacy` and `Wasm3Legacy` compatible with Aidoku Community `.aix` packages.
- Reader stability: prioritize low-memory behavior, image fallback correctness, and retry/reload paths.

## Update Checklist

- Update `docs/TASKS.md` when a task is added, completed, blocked, or reprioritized.
- Update `docs/iOS12_FEATURE_PARITY.md` when feature coverage changes.
- Update `docs/SOURCES_IOS12.md` when source repository, package, or runner compatibility changes.
- Record GitHub Actions run IDs when a pushed fix is verified remotely.

## Verification Log

| Date | Change | Verification |
| --- | --- | --- |
| 2026-06-14 | Legacy reader fallback request compile fixes | `Build iOS 12 legacy IPA` run `27478729161` passed; nightly run `27478729155` passed. |

## Risk Notes

- iOS 12 support depends on `iOSLegacy/AidokuLegacy.xcodeproj` and Xcode 15.4 compatibility.
- Hosted `macos-14` availability is time-limited; be ready to move legacy builds to a self-hosted runner.
- Avoid increasing reader cache or parallelism without checking 1 GB RAM devices.
