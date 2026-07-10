# Injector — Design

Status: Approved (v1 scope)
Date: 2026-07-10

## Summary

Injector is a new third tool in the Aerospace sidebar (alongside Logger and
API Tester) that acts as a local, CodePush-style over-the-air update system
for React Native apps. It lets a developer publish a pre-built JS bundle,
tag it with app/platform/channel/native-version metadata, and have a small
React Native client SDK (built separately, in the consumer's RN project)
poll for, download, verify, and apply that bundle — with automatic crash
rollback if the new bundle fails on its first trial launch.

This is v1 of a system explicitly designed to extend later into a fully
hosted, multi-user CodePush-style service (real rollout percentages, remote
hosting instead of a local Mac, crash reporting back to the publisher). None
of those are in scope now; the data model and client/server contract are
kept simple enough not to block that extension.

## Scope

**In scope (v1):**
- New `Injector` tool in Aerospace: import a bundle file, tag it, publish it,
  view release history, serve it over a local HTTP server.
- A separate RN client SDK (iOS + Android, bare RN) that checks for updates,
  downloads, hash-verifies, applies on next launch, and automatically rolls
  back a release that crashes before completing one healthy trial launch.

**Explicitly out of scope (v1):**
- Running the JS bundler on the user's behalf — the user provides an
  already-built bundle file.
- Percentage/staged rollout — every release is simply "the latest" for a
  given app+platform+channel (subject to native-version compatibility).
- Remote/cloud hosting — bundles are served from the Mac running Aerospace,
  over the local network only.
- Client → Aerospace crash reporting — a rollback happening on-device is not
  surfaced back to the Aerospace UI in v1.
- Offline `.ipa`/`.apk` repackaging (patching a built binary directly) — a
  separate, unrelated capability, not part of this spec.
- Authentication on the HTTP API — the server trusts the local network,
  consistent with Logger's existing (unauthenticated) model.

## Architecture

### Aerospace side (this repo)

Follows the existing per-tool pattern established by Logger and API Tester:
a closed `Tool` enum case, a `@MainActor ObservableObject` store facade, a
SQLite-backed metadata store, and (for tools needing one) an independent
`NWListener`-based HTTP server. Injector does not modify or share
infrastructure with Logger — it clones the pattern into its own files,
consistent with how API Tester was added without touching Logger.

Components:
- `Tool.injector` — new case in the sidebar enum.
- `InjectorStore` — `@MainActor ObservableObject` facade, owns the SQLite
  store and the HTTP server, exposes `@Published` state, injected as an
  `.environmentObject` from `AerospaceApp` (mirrors `LogStore`).
- `SQLiteInjectorReleaseStore` — raw SQLite3 metadata store, same
  create-schema/migrate pattern as `SQLiteLogStore`.
- Bundle binaries are stored as flat files on disk under
  `Application Support/Aerospace/InjectorBundles/<releaseId>/` — SQLite
  never holds blob data, matching existing convention.
- `HTTPInjectorServer` — a new, separate `NWListener`-based server on its
  own configurable port (default `57334`), structurally cloned from
  `HTTPLogServer` (manual switch-based routing, same connection/parser
  handling), but a distinct class/port from Logger's server.
- `InjectorToolView` — SwiftUI screen: file picker to import a bundle, a tag
  form, a release history list, and a server status bar matching Logger's
  widget.

### RN Client SDK (separate deliverable, lives in the consumer's RN project)

Not part of this Xcode project. A small package with a JS API plus native
iOS (Swift) and Android (Kotlin) modules, built fully custom (no
third-party OTA library dependency), targeting bare React Native (or Expo
with a custom dev client/prebuild) on both iOS and Android in v1.

## Data model

One row per published release in `SQLiteInjectorReleaseStore`:

```
id                 — unique release identifier
app                — app identifier string
platform           — "ios" | "android"
channel            — free-form string, e.g. "staging", "prod"
version            — monotonic version string/int, developer-supplied
minNativeVersion   — lower bound of compatible native app version
maxNativeVersion   — upper bound of compatible native app version
bundleHash         — sha256 of the bundle file, computed at publish time
bundlePath         — path to the flat file under InjectorBundles/
createdAt          — timestamp
```

"Latest" for a given `app + platform + channel` is the newest `createdAt`
among releases whose `[minNativeVersion, maxNativeVersion]` range covers the
requesting client's reported native version. There is no rollout percentage
in v1 — a client either gets the latest matching release or nothing.

## Aerospace HTTP API

Served by `HTTPInjectorServer` on its own port, separate from Logger's:

- `GET /injector/check?app=&platform=&channel=&nativeVersion=`
  → `200` with `{ id, version, bundleHash, downloadUrl }` for the latest
  matching release, or `204 No Content` if none matches.
- `GET /injector/bundle/<releaseId>`
  → raw bundle bytes. The client verifies these against the `bundleHash`
  returned by `/check` before treating the download as valid.
- `GET /health` → `{"status":"healthy"}`, mirrors Logger's.

## Aerospace UI

`InjectorToolView`:
- File picker to import a built `.bundle` file (+ optional assets folder).
  Aerospace does not invoke a bundler.
- Tag form: app id, platform, channel, version, min/max native version.
- "Publish" button: copies the file into flat storage, computes its hash,
  inserts a metadata row.
- Release history list per app, newest first.
- Server status bar (start/stop/port), matching Logger's widget.

## RN client: state and boot flow

State tracked natively (`UserDefaults` on iOS / `SharedPreferences` on
Android), scoped per `app + platform + channel`:

```
currentReleaseId       — the release currently considered "good"
pendingReleaseId       — a newly downloaded release awaiting its trial launch
lastKnownGoodReleaseId — last release that passed a health check
pendingHealthCheck     — bool, set true immediately before a trial launch
badReleaseIds          — set of releases that failed rollback; never retried
```

JS API:
- `Injector.checkForUpdate({ app, channel })` — calls `GET /injector/check`,
  compares the result against `currentReleaseId` and `badReleaseIds`.
- `Injector.downloadUpdate(release)` — fetches `GET /injector/bundle/<id>`,
  verifies its SHA-256 against the hash from `/check`, writes it to the
  app's writable directory, and sets `pendingReleaseId` +
  `pendingHealthCheck = true`. The update is **applied on next launch**,
  not immediately, to avoid mid-session bridge-reload instability.
- `Injector.notifyAppReady()` — called by app code once the app has mounted
  and looks healthy (e.g. a few seconds after first render).

Native boot sequence, run before JS starts, overriding `jsBundleURL` (iOS)
or `getJSBundleFile()` (Android):

1. If `pendingHealthCheck == true` from the *previous* launch (meaning
   `notifyAppReady()` was never called — crash, hang, or force-quit before
   it fired): add `pendingReleaseId` to `badReleaseIds`, revert
   `currentReleaseId` to `lastKnownGoodReleaseId` (or the embedded default
   bundle if none), clear `pendingReleaseId` and `pendingHealthCheck`.
2. Otherwise, if `pendingReleaseId` is set (a fresh download awaiting its
   trial): promote it to `currentReleaseId` and set
   `pendingHealthCheck = true` for this launch — this is now the trial run.
3. Load whichever bundle `currentReleaseId` resolves to. If that bundle
   file is missing or corrupted on disk, fall back to the embedded default
   bundle regardless of rollback state (an independent safety net).
4. Once JS mounts and calls `notifyAppReady()`, native sets
   `pendingHealthCheck = false` and `lastKnownGoodReleaseId =
   currentReleaseId`.

This gives exactly one trial launch per update: a crash before
`notifyAppReady()` causes the *next* launch to revert automatically and
blocklist that release, preventing a crash-update-crash loop.

## Error handling

**Aerospace side:**
- Publish is rejected if `minNativeVersion > maxNativeVersion`, or if the
  bundle file is unreadable / its hash can't be computed.
- Port-in-use or bind failure surfaces via `ServerState.failed`, the same
  mechanism Logger already uses.

**Client SDK side:**
- `checkForUpdate()` network failures are swallowed — treated as "no
  update available"; the app continues running its current bundle and is
  never blocked or crashed by a failed check.
- A downloaded bundle that fails hash verification is discarded silently;
  it is not set as `pendingReleaseId` and is not retried automatically.
- A release that fails its trial launch is added to `badReleaseIds` and is
  never re-downloaded automatically, even if the server still reports it as
  latest — this is what prevents an infinite crash-update-crash loop.
- If the bundle file resolved by `currentReleaseId` is missing or corrupted
  at boot, native code falls back to the embedded default bundle regardless
  of rollback state.

## Testing

**Aerospace side:**
- Unit tests for `SQLiteInjectorReleaseStore`: schema/migration, CRUD, and
  the "latest matching release" query, including native-version range
  comparison — mirrors existing `AerospaceTests` coverage of
  `SQLiteLogStore`.
- Unit tests for `HTTPInjectorServer` routing (`/check`, `/bundle/<id>`,
  404s), reusing existing parser/server test patterns from Logger.
- Manual UI pass: import → tag → publish → appears in release history.

**Client SDK side:**
- The boot decision logic (given the state flags above, what should boot
  do) is factored out as a plain, pure function — unit-testable without
  touching real `RCTBridge`/file I/O.
- Native boot integration itself is not meaningfully unit-testable. The
  implementation plan should include a small example RN app used to
  manually validate the full loop end-to-end: publish a good bundle →
  confirm it installs on next launch → publish a bundle that intentionally
  throws before mount → confirm automatic rollback and blocklisting.

## Implementation sequencing

This spec covers two distinct implementation surfaces that will become two
separate implementation plans, built in this order:

1. **Aerospace Injector tool** (this Xcode project) — `InjectorStore`,
   `SQLiteInjectorReleaseStore`, `HTTPInjectorServer`, `InjectorToolView`.
   Can be built and manually verified (publish a bundle, fetch it with
   `curl`) without the client SDK existing yet.
2. **RN client SDK** (a separate package, in a consumer RN project) — native
   iOS + Android modules, boot/rollback logic, JS API. Depends on #1's HTTP
   API being stable, and needs an example RN app to validate against.

## Extension points (not built now, but not blocked by this design)

- Rollout percentage / staged rollout — would add fields to the release
  row and a decision in the `/check` query; does not change the client
  contract shape.
- Remote/cloud hosting — `/check` and `/bundle` could be served by a
  different backend entirely; the client only depends on those two routes
  existing somewhere.
- Crash reporting back to Aerospace — would add a
  `POST /injector/report` route and a corresponding client call at the
  point where a release is added to `badReleaseIds`.
