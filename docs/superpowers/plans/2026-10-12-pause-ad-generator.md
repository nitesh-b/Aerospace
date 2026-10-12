# Pause Ads Tool — Implementation Plan

**Goal:** A "Pause Ads" tool in Aerospace that turns a designer hand-off folder (AEP + lottie `data.json` + `images/` + youi `assets/`) into a youi.ads-compatible pause ad, serves it locally for uap.rn / youi.rn testing, and produces the deployment zip — with no dependency on the You.i engine (`generate_manifest.rb`), Ruby, Node or 7z.

**Architecture:** Pure-Swift port of the youi.ads pipeline (`setup-s/h` → copy → `auto` → `gen` → `deploy`). File-system logic lives in `nonisolated` value types under `Aerospace/PauseAds/` (unit-testable, no UI). `PauseAdStore` (`@MainActor ObservableObject`) owns form state, folder bookmarks and the hosted-ad list. The Logger's existing `HTTPLogServer` on port 57333 gains a `GET/HEAD /files/*` route backed by a resolver closure the store installs, so URLs keep the youi.ads shape.

**Tech Stack:** SwiftUI (macOS), Foundation (`FileManager`, `NSFileCoordinator`), Network framework, XCTest. No third-party packages.

## Decisions (agreed 2026-10-12)

| Topic | Decision |
|---|---|
| Hosting | `/files/*` route added to Logger server (57333). Ads served only while Logger server runs. |
| Destination layout | Full youi.ads tree under destination root: `ads/{sales\|house}/{YYYY}/{folder}/{MM}{Mon}/pause/p-{job}/v{n}/` |
| Re-run same job | Prompt: overwrite latest version / create next version / cancel |
| Image swap | Per file, only when youi is smaller **and** pixel dimensions match, with same name, copy `assets/drawable/default/X` over `images/X` **in the destination copy only** when smaller. Source folder never mutated. Report swaps. |
| `generate_manifest.rb` | Ported to Swift. No C++ (no benefit; app is pure Swift). |
| 7z | Replaced with `NSFileCoordinator(.forUploading)` zip; zip root entry `RemoteManifest/`. |
| Deploy wipe | CLI `rm -rf deployments` NOT replicated. Only the target zip is written. |
| Deploy filename | `{title}-dpm-{yyyy-MM-dd}.zip` (doc's manual rename, automated). |
| Out of scope | Interactive ads (`autoi`, runtime code encryption), `dynamicAssets`, in-app lottie preview. |

## Behaviour parity reference (youi.ads)

- **setup:** month folder = `MM` + en-GB short month (`10Oct`, September → `Sept`). Ticket prefixed `p-` unless already (**improvement:** `P-` also recognised, CLI produced `p-P-…`). Year = current year. Month names from a fixed table — Foundation en_GB yields `Sep`, Node yields `Sept`.
- **existing job lookup (improvement):** by ticket across `ads/{type}/*/*/*/pause/`; CLI only noticed a clash in the current month folder.
- **auto (metadata derivation):**
  - `target` = basename of `*_main.layout` / `*_Main.layout`; fallback to `.aep` prefix (warn: youi.rn will not render).
  - `lottieTarget` = `data.json` when present.
  - `duration` = `duration:` of the `markers` block containing `Ad-In` in `*.timeline.log`. **Improvement:** fallback to `data.json` marker `cm == "Ad-In"` → `dr / fr` (verified equal for Specsavers: 232/60 = 3.8667 vs 3.86666656).
  - `loop` = any `markers` chunk contains `Loop` (also check lottie markers `cm`).
  - brand/campaign/industry from form; `upNextModifierTime` default 0.
- **inspector validated** against all 299 repo ads with metadata: 295 identical derived fields; 4 differences are wrong committed metadata (stale warrl duration, 1.0 fallbacks, hand-edited target).
- **target choice:** multiple main layouts → prefer `{aepPrefix}_main`; same layout in several device folders → prefer `assets/layout/tv/`; `tv-rklow` ignored (as CLI).
- **manifest port validated:** Ruby vs Swift on the Specsavers download + all 80 youi.ads pause ads from 2025–2026 — identical copied files and byte-identical `RemoteManifest.json` (children order normalized). Deviations: sorted entries, all dot-files skipped (no `._*`), case-insensitive `.aep`/`.log` exclusion, staged build swapped in at the end.
- **gen:** copy `server/` → `manifests/RemoteManifest/` excluding extensions `.log`, `.aep` and names `.`, `..`, `.DS_Store`, `__MACOSX`, `.git`; write `RemoteManifest.json` `{manifest_version:"1.0.0", minimum_engine_version:"4.6.0", maximum_engine_version:"999.999.999", asset_catalog:[{name, children?}]}` (pretty, trailing newline; written before metadata copy so it does not list `metadata.json`). Then write `RemoteManifest/metadata.json` with `adBrandName/adCampaign/adIndustry` → lowercase, remove all `&` and `-`, collapse 2+ spaces to one.
- **deploy:** zip `RemoteManifest/` → `deployments/{type}/{year}/{folder}/{MMMon}/pause/p-{job}/v{n}/{title}.zip`, `title = target.split("_")[0]`, `()` → `_`, whitespace → `_`.
- **hosting:** `GET /files/<rel>` → `<destinationRoot>/<rel>` (percent-decoded). Added: traversal guard (resolved path must stay under root), HEAD, MIME map (json, png, jpg, js, zip, txt…), `Access-Control-Allow-Origin: *`.

## Global Constraints

- No `project.pbxproj` edits — `PBXFileSystemSynchronizedRootGroup` picks up new files/folders.
- Model/logic types `nonisolated struct`/`enum`, `Sendable`. Store `@MainActor final class … ObservableObject`.
- Entitlements: add `com.apple.security.files.bookmarks.app-scope` (persist source/destination access across launches; server needs destination access after relaunch).
- Persistence: UserDefaults keys `pauseAds.sourceBookmark`, `pauseAds.destinationBookmark`, `pauseAds.lastForm`.
- Build: `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet`
- Test: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/<Class> -quiet`
- Logic TDD with XCTest; views verified by build + manual smoke test.

## File Structure

**Create**
- `Aerospace/PauseAds/PauseAdMetadata.swift` — metadata model, ordered JSON writer (key order matches template), normalizer.
- `Aerospace/PauseAds/PauseAdJob.swift` — ad type, folder name, job code, version → relative paths (version dir, server, manifests, deployment zip).
- `Aerospace/PauseAds/PauseAdInspector.swift` — inspects a source folder: files found, derived metadata, missing image refs, size totals, youi-vs-lottie image comparison, errors/warnings.
- `Aerospace/PauseAds/RemoteManifestBuilder.swift` — Swift port of `generate_manifest.rb`.
- `Aerospace/PauseAds/PauseAdGenerator.swift` — orchestrates setup → copy → image swap → metadata → manifest.
- `Aerospace/PauseAds/PauseAdDeployer.swift` — validation + zip.
- `Aerospace/PauseAds/PauseAdFileResolver.swift` — URL path → file URL with traversal guard + MIME lookup; thread-safe root holder.
- `Aerospace/PauseAds/HostedPauseAd.swift` — discovered ad (rel path, metadata, mtime) + URL builder.
- `Aerospace/Storage/PauseAdStore.swift` — form state, bookmarks, generate/deploy actions, hosted list scan, rotation snippet.
- `Aerospace/Views/PauseAdToolView.swift`, `PauseAdFormView.swift`, `PauseAdInspectionView.swift`, `HostedPauseAdsView.swift`.
- Tests: `PauseAdMetadataTests`, `PauseAdJobTests`, `PauseAdInspectorTests`, `RemoteManifestBuilderTests`, `PauseAdGeneratorTests`, `PauseAdDeployerTests`, `PauseAdFileResolverTests`, `HTTPLogServerFilesRouteTests`.

**Modify**
- `Aerospace/Server/HTTPLogServer.swift` — `fileResolver` hook, `/files/*` GET/HEAD route, binary response path.
- `Aerospace/Storage/LogStore.swift` — expose `setFileResolver(_:)` and current port for URL building.
- `Aerospace/Views/RootView.swift` — `Tool.pauseAds`.
- `Aerospace/AerospaceApp.swift` — create `PauseAdStore`, inject, wire resolver into `LogStore`.
- `Aerospace/Aerospace.entitlements` — bookmarks entitlement.

## Tasks

- [x] **1. Metadata model + normalizer.** Ordered writer; normalizer parity cases (`"Style and fashion"` → `"style and fashion"`, `"Big-Brother & Co"` → `"bigbrother co"`, double spaces). Validation: `isDeployable` requires non-empty brand/campaign/industry, target, lottieTarget, duration > 0.
- [x] **2. Job paths.** `p-` prefixing, en-GB month folder, version discovery (`v1…vn`), deployment path/title sanitising.
- [x] **3. Inspector.** Fixture-built temp folders: lottie+youi, lottie-only (duration from `data.json`), missing image ref (error), `Loop` marker, `_Main` vs `_main`, size thresholds (warn > 3 MB, stronger warn > 5 MB — advisory only, Big Brother 2026 shipped at 7–9 MB), image swap candidates.
- [x] **4. RemoteManifestBuilder.** Exclusions, nested children, existing bundle replaced, JSON shape. One-off manual parity check: run Ruby + Swift on the Specsavers Downloads folder in scratch dirs, compare trees order-insensitively.
- [ ] **5. Generator.** Fresh job, overwrite version, next version, image swap applied to destination only, source untouched, metadata written to `v{n}/metadata.json` and normalized copy in `RemoteManifest/`.
- [ ] **6. Deployer.** Blocks on missing fields; zip root is `RemoteManifest/`; filename; only target zip written. Verify entry layout against an existing youi.ads deployment zip.
- [ ] **7. File route.** Resolver traversal (`..`, encoded `%2e%2e`, absolute), MIME, 404, HEAD; `HTTPLogServer` route wired; `/log` and `/health` unchanged.
- [ ] **8. Store.** Bookmarks resolve/refresh stale, start/stop security-scoped access, form persistence, existing-job detection (load existing metadata into form), hosted list scan (`**/manifests/RemoteManifest/metadata.json`, newest first), rotation snippet.
- [ ] **9. Views.** Source/destination pickers (+ drag & drop), type picker, folder name, job code, metadata fields, inspection checklist, **Generate Pause Ad**, **Deploy** (disabled until deployable), re-run dialog, hosted list with copy URL / reveal in Finder / multi-select → `pauseAdRotation` snippet, banner when Logger server stopped. Uses Logger LAN IP setting for host.
- [ ] **10. Entitlement + wiring + README section.** Manual smoke: generate Specsavers, fetch `metadata.json`, `data.json`, an image via curl from LAN IP, load in uap.rn Android TV emulator with `useLocalPauseAds: true`.

## Resolved questions

- `adIndustry` is free text (no dropdown).
- Up-next ads share the metadata shape but are not tested.
