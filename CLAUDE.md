# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ClaudeMeter: a macOS menu bar app plus a WidgetKit widget that display Claude Code
subscription usage, read from `GET https://api.anthropic.com/api/oauth/usage` using the
OAuth token Claude Code already stores. Built with the Command Line Tools only — there is
no Xcode project, no Package.swift, and no test suite.

## Build and run

```bash
./build.sh                                   # compiles both targets, assembles + ad-hoc signs build/ClaudeMeter.app
cp -R build/ClaudeMeter.app /Applications/   # must live in /Applications for the widget to register
open /Applications/ClaudeMeter.app
```

Always run the `/Applications` copy, never `build/ClaudeMeter.app` directly. The widget is
always loaded from `/Applications`, so launching from `build/` leaves the widget on whatever
build was last installed. It also leaves two app instances running if the installed one is
open too: both refresh on their own timers, which doubles calls against the shared
rate-limit budget, and the older one keeps writing `state.json` with superseded logic. To
reinstall, `killall ClaudeUsage` and `rm -rf /Applications/ClaudeMeter.app` before the `cp`
(copying over an existing bundle can leave stale files behind), then `killall chronod` so
the widget picks up the new build.

`build.sh` compiles twice from one source tree:

- **App** — `Shared/*.swift App/*.swift` → `Contents/MacOS/ClaudeUsage`, unsandboxed.
- **Widget** — `Shared/*.swift Widget/*.swift` → `Contents/PlugIns/ClaudeUsageWidget.appex`,
  built with `-application-extension` and linked `-Xlinker -e -Xlinker _NSExtensionMain`.
  That entry-point flag is load-bearing: without it the extension dies instantly with
  "Unrecognized extension type" and chronod only reports "Launch failed." Verify with
  `nm -u <appex binary> | grep NSExtensionMain`.

Render the widget faces to PNGs without placing a widget (this is how `docs/` was made):

```bash
CCU_RENDER_PREVIEWS=/some/dir build/ClaudeMeter.app/Contents/MacOS/ClaudeUsage
```

### Widget iteration gotchas

- **Bump `CFBundleVersion` in `Support/Widget-Info.plist` after changing widget code.**
  chronod caches extension descriptors and will not relaunch the appex otherwise, so you
  will be looking at the previous build's render.
- `killall chronod` forces a rescan of the widget gallery.
- `pluginkit -m -v -i com.swarnim.ClaudeCodeUsage.Widget` says whether it registered.
- Use the **full path** `/usr/bin/log show --last 5m --info --debug --predicate 'subsystem == "com.apple.chrono"'`
  — zsh's `log` builtin shadows it and fails with "too many arguments".
- The extension appends lifecycle stages to
  `~/Library/Application Support/ClaudeCodeUsage/widget-trace.log`
  (`bundle.init` → `bundle.body` → `widget.body` → `provider.*`) via `Store.trace`. Since
  macOS launches it on its own schedule inside a sandbox, this is the practical way to see
  how far it got.

`build.sh` may create `.toolchain-shim/` — a shadow toolchain that works around a CLT
install carrying duplicate `SwiftBridging` modulemaps. It is created only when that
condition is detected; do not check it in. It *copies* `swift-frontend` but symlinks
`usr/lib`, so a CLT update leaves an old compiler pointed at new dylibs and it aborts
with `dyld: Symbol not found`. `build.sh` compares mtimes and rebuilds the shim when
that happens; if you ever see that abort, `rm -rf .toolchain-shim` is the manual fix.

### No `@State` — the CLT ships no macro plugin

As of the Swift 6.4 CLT, SwiftUI's `@State` **attribute** resolves to a macro
(`SwiftUIMacros.StateMacro`) whose plugin ships only inside Xcode, so using it fails
with "plugin for module 'SwiftUIMacros' not found". The `State` property wrapper
itself is still in SwiftUICore, and SwiftUI locates storage by walking the view's
`DynamicProperty` fields rather than by name, so declare it directly instead:

```swift
private var _showHistory = State(initialValue: false)   // not @State
// ... and use _showHistory.projectedValue where $showHistory would go
```

`@Environment`, `@EnvironmentObject`, `@StateObject`, `@ObservedObject`, `@Binding`
and `@Published` are ordinary property wrappers and are all still fine. Only `@State`
(and `@Entry`, `@Animatable`, `@Previewable`) became macros.

## Architecture

```
Shared/   Model, Store, Credentials, Fetcher, UsageViews  — compiled into BOTH targets
App/      Menu bar status item, popover panel, preview renderer
Widget/   WidgetBundle + TimelineProvider
Support/  Info.plists, entitlements, icon generator
```

Anything in `Shared/` is compiled into the sandboxed extension too, so it must not assume
the app's privileges (see the home-directory and Keychain notes below).

**Two processes, one file.** The app and widget coordinate through
`~/Library/Application Support/ClaudeCodeUsage/state.json` (`Store`). App groups were not
usable — `containermanagerd` will not vend a group without a real Team ID — so the widget
reaches this folder through a sandbox temporary exception in `Support/Widget.entitlements`.
Because of that sandbox, `Store.realHome` resolves the home directory via `getpwuid`;
`FileManager.homeDirectoryForCurrentUser` returns the container inside the extension and
must not be used for shared paths.

**Division of labour.** The app holds Keychain access (`/usr/bin/security` reading
"Claude Code-credentials"), refreshes every 5 minutes plus on wake, on panel open, and on
`claudeusage://refresh` (the widget's tap target, handled in `AppDelegate.application(_:open:)`),
then calls `WidgetCenter.reloadAllTimelines()`. The widget normally just renders the stored
snapshot; it fetches on its own only when the snapshot is >10 min old or a reset boundary
has passed. Each timeline carries 90 per-minute entries so countdowns tick with no network
traffic.

## Invariants worth preserving

These encode fixed bugs; changing them regresses real behaviour.

- **Never fabricate a number.** `Fetcher.parse` returns nil rather than a snapshot with no
  usage rows, and failures are recorded as a typed `FetchErrorKind` (`auth`, `network`,
  `service`, `rateLimited`) while the last good snapshot stays on screen, labelled stale.
- **Decoding is deliberately lenient.** `StoreState.init(from:)` and
  `FetchErrorKind.init(from:)` swallow unknown/unparseable fields. A strict decode used to
  discard the last good reading when one build wrote a value another couldn't parse.
- **`Store.save` only ever adds.** If the caller's state has no snapshot or empty history it
  merges in what is already on disk, so a partial write cannot blank the widget.
- **The rate-limit budget is shared.** The app and every widget timeline process draw on one
  quota. `Fetcher.refresh` claims `lastAttemptAt` on disk *before* the network call so
  concurrent processes don't all fire; `minimumInterval` coalesces bursts; a `retryAfter`
  cooldown is honoured even for user-initiated refreshes. `Retry-After` is clamped to
  30s–15m and consecutive limits back off by doubling.
- **Expired tokens are never sent.** `Credentials.token()` returns nil when every stored copy
  is past expiry (with a 60s margin), because Claude Code leaves a stale copy on disk and a
  doomed request only spends rate limit. Credentials are strictly read-only — this app never
  writes, refreshes, or rotates them.
- **The extension must stay sandboxed** (`com.apple.security.app-sandbox`); `pkd` refuses to
  register an unsandboxed app extension, and it simply never appears in the gallery.

## Conventions

- Comments here explain *why* — usually a macOS behaviour or a bug that was hit. Keep that
  register; don't strip them.
- `Shared/UsageViews.swift` is the single source of truth for the widget faces, used by the
  widget, the panel, and the preview renderer. Change the design there, not per-target.
- Bundle IDs are `com.swarnim.ClaudeCodeUsage` and `com.swarnim.ClaudeCodeUsage.Widget`,
  hardcoded in `build.sh` and the plists.
