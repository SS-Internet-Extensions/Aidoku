# Tasks

This is the short task board for AidokuLegacy work. Move items between sections rather than leaving stale notes in chat.

## Active

- Keep `AidokuLegacy (iOS 12)` green in GitHub Actions after each pushed change.
- Watch reader crashes and image fallback failures on low-memory iOS 12 devices.
- Track source compatibility regressions against Aidoku Community `.aix` packages.

## Next

- Add focused tests for legacy package install, runner calls, image request fallback, downloads, and backup restore.
- Fill high-value gaps listed in `docs/iOS12_FEATURE_PARITY.md`, starting with reader/download hardening and library update correctness.
- Review GitHub Actions Node 20 deprecation warnings and update workflow actions before runner defaults change.

## Blocked Or Deferred

- Tracker sync, local files, and full modern backup parity remain deferred until the core source runner and reader paths are stable.
- Hosted legacy CI may require a self-hosted macOS 14/Xcode 15.4 runner if GitHub removes `macos-14`.

## Done

- `2026-06-14`: Fixed legacy reader fallback request compile errors and verified both legacy IPA and nightly GitHub Actions builds passed.
