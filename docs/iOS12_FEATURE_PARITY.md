# AidokuLegacy iOS 12 Feature Parity

This tracks how much of the original Aidoku app is covered by the `AidokuLegacy (iOS 12)` target. The legacy target is a compatibility fork for iOS 12 devices, so parity means preserving the core read-from-community-sources workflow rather than matching every modern app feature.

## Covered

| Original Aidoku area | AidokuLegacy coverage |
| --- | --- |
| App shell | UIKit tab shell with Library, History, Sources, Browse, and Settings. |
| Community source catalog | Loads configured source repositories, searches sources, resolves icons/package URLs, downloads `.aix` packages, and installs them locally. |
| Installed source management | Lists installed sources, opens source menus, updates installed packages manually or automatically, and supports repository add/reset flows. |
| AidokuRunner source execution | Runs installed `.aix` WASM packages through `AidokuRunnerLegacy`/`Wasm3Legacy` for search, listings, home, manga updates, page lists, image requests, page processing, alternate covers, settings, and login hooks. |
| Source browsing | Supports source home pages, static/dynamic listings, source search, pagination, saved filters, source settings, language selection, base URL selection, and source website browsing. |
| Manga details | Loads details and chapters, adds/removes manga from the local library, filters chapter language, resumes reading, and starts from the first readable chapter. |
| Reader | Supports vertical scroll, vertical fit, paged LTR, and paged RTL modes; page number overlay; tap zones; image cache; WebP/AVIF-aware loading; source image-request hooks; page processing; and low-memory downsampling/upscaling controls. |
| Library and history | Stores library entries, manga tags, multiple categories, saved filter groups, sort/search state, reading history, last reader session, and cover repair metadata in legacy-local storage. |
| Updates | Manual and optional automatic library checks record newly discovered chapters in a local updates list. |
| Downloads | Downloads chapters for offline reading, opens downloaded chapters in the reader, reports progress, deletes individual downloads, and clears all downloads. |
| Backup/restore | Exports and imports a legacy JSON backup containing library, history, updates, repositories, and legacy settings. |
| Basic settings | Provides reader memory/layout controls, appearance toggle, automatic library/source update toggles, cache/history/library clearing, and downloads management. |

## Missing Or Partial

| Area | Status |
| --- | --- |
| Tracker integration | Missing. No AniList/MAL/Kitsu/etc. account auth, registration, progress sync, or tracker backup data. |
| Modern backup system | Partial. Legacy JSON backup exists, but not the full modern backup model, automatic backup scheduling, selective content options, iCloud storage, or tracker/download parity. |
| Local files | Missing. No local archive/PDF/import source workflow from the modern app. |
| Self-hosted/custom sources | Missing. No Komga/Kavita/self-hosted setup flows. |
| Deep links and URL imports | Partial. Source website browsing and web login exist, but modern app URL handling for source lists, source imports, backups, files, tracker OAuth callbacks, and source deep links is not ported. |
| Source migration hooks | Partial. The runner detects migration-related exports, but the app does not port the modern source key/chapter migration UI or Core Data migration flow. |
| Background work | Partial. Source/library checks and downloads are callback-based, but they do not match the modern background download manager, background processing, or resume/pause behavior. |
| Notifications | Partial. Runner notification hooks exist, but there is no full user-facing notification or update notification system. |
| Library richness | Partial. Core library, manga tags, multi-category filters, saved filter groups, search, and sort exist, but modern unread counts, pins, rich grouping, custom display settings, and Core Data-backed state are not ported. |
| Reader feature depth | Partial. Core reading works, but advanced modern reader controls, gestures, transitions, reading-state sync, and all media/page variants are not guaranteed; ZIP pages are explicitly unsupported in the legacy reader/downloader. |
| Localization | Missing/partial. Most legacy UI strings are hard-coded English rather than using `Shared/Localization`. |
| Tests | Missing. There are no focused XCTest cases for the legacy catalog, package installer, runner bridge, stores, backup, downloads, or reader behavior. |

## Implementation Priorities

1. Stabilize source execution: keep `AidokuRunnerLegacy`/`Wasm3Legacy` compatible with current community `.aix` packages, add smoke tests around package install, search/listing/details/page execution, and document unsupported source APIs.
2. Harden the reader and downloads: verify low-memory behavior on iPad Air 1-class devices, improve ZIP/page variant handling, and add regression tests for offline manifests and image-request fallbacks.
3. Improve library/update correctness: add tests for category/sort/search persistence, update detection, cover repair, and history/session resume.
4. Fill high-value import/export gaps: add modern backup import/export compatibility where practical, then handle source-list and backup URL imports.
5. Decide tracker scope: either explicitly keep tracker sync out of AidokuLegacy or port a minimal tracker model with auth, progress updates, and backup support.
6. Add source migration/deep-link support only after the core runner and storage paths are tested, because mistakes here can silently orphan library/history entries.
7. Localize user-facing legacy strings after the feature set settles.
