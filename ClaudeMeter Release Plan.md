---
title: ClaudeMeter — Release Plan
created: 2026-09-02
updated: 2026-09-20
status: in-progress
target: Developer ID (website) → App Store (blocked)
tags: [project/claudemeter, macos, swift, widgetkit, release, distribution]
---

# ClaudeMeter — Release Plan

> [!summary] Verdict
> **Shippable from your own website within a day or two.** Not shippable to the
> Mac App Store without either a redesign of how it gets a token, or written
> permission from Anthropic — probably both. The two tracks are independent;
> Track A does not depend on Track B ever happening.

Repo: `mandalswarnim/claude-meter` · Branch `main` · HEAD `50c05f0`

---

## 1. Where it stands today

### 1.1 Landed 2026-09-02

| Commit | Change |
|---|---|
| `7176e4d` | Fetch results now apply to current on-disk state, not a pre-flight copy |
| `7176e4d` | `UsageSnapshot` given tolerant decoding; appex `CFBundleVersion` 4 → 5 |
| `443cf3e` | `CLAUDE.md` — build, widget traps, architecture, invariants |

**Why the first one mattered.** A fetch can be in flight for 15 seconds, and the
app and widget refresh independently. Both loaded state, awaited the network,
then saved the copy loaded *before* leaving — rolling back whatever the other
process wrote meanwhile. Worst case: the widget takes a 429 and records a
cooldown; a user-initiated app refresh (which passes `minimumInterval: 0` and so
does not coalesce) lands afterwards and writes `retryAfter` back to nil. Cooldown
gone → next poll fires inside the server's window → fresh 429 → longer block.

Now every result routes through `Fetcher.commit()`, which re-reads state and
applies only what the attempt learned. On success a cooldown is cleared **only if
already lapsed** — one still in force was set after the request left, and it
speaks for the shared budget, not for this one reply.

**Why the second one mattered.** Swift's synthesized decoder ignores property
defaults, so `extraUsageEnabled` was a *required* key. A `state.json` from a build
without it threw and discarded the whole snapshot — blanking the widget. That is
the exact regression `716f340` fixed for `StoreState`, sitting one struct further
down. Verified before/after against crafted JSON:

```
before → old-schema snapshot survived: false
after  → old-schema snapshot survived: true   session: 42   extraEnabled: false
```

### 1.2 Landed 2026-09-20

| Commit | Change |
|---|---|
| `14a0bbf` | Restore the build under the Swift 6.4 CLT — shim staleness detection, `@State` workaround |
| `db70ce8` | Stop a session-only refresh zeroing the day's weekly history figure |
| `50c05f0` | Clear the §1.3 backlog: the compiler warning, day-key locale, the dead line; appex `CFBundleVersion` 5 → 6 |

> [!danger] The build was dead, not merely warning
> `./build.sh` aborted before compiling a file. Anyone cloning this repo on a
> current CLT hit the same wall. Both causes came from the 12 Sep CLT update.

**The shim went stale — again.** `.toolchain-shim` copies `swift-frontend` but
symlinks `usr/lib`, so a CLT update leaves an old compiler pointed at new
dylibs: `dyld: Symbol not found`. The README already described this as a manual
`rm -rf`. `build.sh` now compares mtimes and rebuilds it unprompted.

**`@State` is no longer usable from the Command Line Tools.** This one is
structural, not a transient bug. In Swift 6.4 the `@State` *attribute* resolves
to a macro, `SwiftUIMacros.StateMacro`, whose plugin ships only inside Xcode —
the CLT carries `libObservationMacros` and `libSwiftMacros` and nothing for
SwiftUI. With no Xcode on the machine, every `@State` fails:

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not
be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

The `State` property wrapper is still in SwiftUICore, and SwiftUI finds storage
by walking the view's `DynamicProperty` fields rather than by name, so declaring
it directly is what the macro would have expanded to anyway. `PanelView` now
does that. `@Environment`, `@EnvironmentObject`, `@StateObject`,
`@ObservedObject`, `@Binding` and `@Published` are unaffected — only `@State`,
`@Entry`, `@Animatable` and `@Previewable` became macros. Documented in
`CLAUDE.md`, because the next view edit walks straight into it.

> [!note] This is a second argument for the Developer Program
> An Xcode install would make the macro plugin available and retire the shim
> entirely. Track B needs an Xcode project regardless (§3.3).

**The history bug.** `Fetcher.parse` accepts a payload carrying *one* real usage
row, so `weeklyPercent` can legitimately be nil. `recordHistory` coerced it with
`?? 0` and assigned it outright, overwriting the day's real weekly reading with
a fabricated zero — the "never fabricate a number" invariant broken one function
below where the parser enforces it. The stored history shows the signature:
09-10 weekly `0` between `4` and `1`, 09-17 zeroed between `2` and `0`.

```
before:                     maxSession=40 lastWeekly=37
after session-only refresh: maxSession=40 lastWeekly=0
```

### 1.3 Known issues still open

None block release.

- [x] `Shared/Model.swift:97` — `as? [DayHistory]` no-op downcast; the only compiler warning — *fixed `50c05f0`*
- [x] `Shared/Model.swift:109,115` — `Fmt.localDayKey`/`dayLabel` `DateFormatter` with no locale — *fixed `50c05f0`, pinned to `en_US_POSIX` + Gregorian*
- [x] `App/PreviewRenderer.swift:59` — `performAsCurrentDrawingAppearance {}` empty closure — *fixed `50c05f0`*
- [ ] `App/AppMain.swift:37` — `guard !isRefreshing` silently drops a click during an in-flight refresh. Mostly hidden in the panel (the button is swapped for a spinner), but a `claudeusage://refresh` widget tap landing mid-refresh is simply ignored
- [ ] `App/AppMain.swift:60` — `UsageController.menuBarTitle` is dead; `AppDelegate` computes the title inline at :105
- [ ] `Shared/UsageViews.swift:26` — `UsageBar` uses `max(6, …)`, so **0% draws a coral dot**. Reads as "some usage" when there is none; visible in the panel screenshot at Weekly 0%
- [ ] Diagnostics ship enabled. `Store.trace` writes 8 lines per widget launch and `writeDebugMarker` writes on every state change. Gate both before release — `recordWidgetHeartbeat` must stay, the panel footer depends on it

### 1.4 Current build reality

```
Signature=adhoc          TeamIdentifier=not set
0 valid codesigning identities on this machine
App entitlements: none at all (unsandboxed)
Appex entitlements: sandbox + network.client + two temporary exceptions
Architecture: arm64 only (TARGET in build.sh)
Minimum OS: macOS 15.0
```

Missing for any signed distribution: `PrivacyInfo.xcprivacy`,
`LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption`,
`NSHumanReadableCopyright` (currently empty), hardened runtime.
`CFBundleVersion` is still `1` on the app (the appex is at `6`).

---

## 2. Track A — Ship from your website ✅ recommended

Developer ID + [[Notarization]]. This path keeps the current credential design
**intact**: an unsandboxed app may spawn `/usr/bin/security`, and sandbox
temporary exceptions are legal for Developer ID. Nothing about how the app works
has to change.

It also fixes a limitation the README already admits: *"copying the built app to
another Mac will trip Gatekeeper."*

### 2.1 Prerequisites

- [ ] Apple Developer Program membership — **$99/yr**, ~24-48h to activate
- [ ] Create a **Developer ID Application** certificate; install in login Keychain
- [ ] App-specific password *or* App Store Connect API key for `notarytool`
- [ ] Store credentials once: `xcrun notarytool store-credentials`

### 2.2 Code and build changes

- [ ] Replace ad-hoc `codesign --sign -` in `build.sh` with the real identity
- [ ] Add `--options runtime --timestamp` (hardened runtime + secure timestamp are both required for notarization)
- [ ] Keep inner-to-outer signing order — appex first, then app. `build.sh` already does this correctly
- [ ] Add `NSHumanReadableCopyright`, `LSApplicationCategoryType` (`public.app-category.developer-tools`), `ITSAppUsesNonExemptEncryption = false`
- [ ] Build **universal** (`arm64` + `x86_64`) or state Apple Silicon–only on the download page
- [ ] Decide a real versioning scheme; `CFBundleVersion` is still `1`

> [!warning] The appex needs the entitlements too
> Both binaries must carry hardened runtime. The widget keeps its sandbox and its
> two temporary exceptions — those are fine here, and *only* here. See [[App Sandbox]].

### 2.3 Package and notarize

- [ ] Package as DMG (nicer) or ZIP (simpler)
- [ ] `xcrun notarytool submit <pkg> --keychain-profile <name> --wait`
- [ ] `xcrun stapler staple` the app **and** the DMG
- [ ] Verify on a clean Mac: `spctl -a -vvv -t install ClaudeMeter.app` → `accepted, source=Notarized Developer ID`

### 2.4 Website

- [ ] Download page: requirements (macOS 15+, Claude Code installed and signed in), screenshots from `docs/`, honest note that the usage endpoint is undocumented and may change
- [ ] Install instructions — the widget must be in `/Applications` to register; include the `killall chronod` tip
- [ ] Publish the privacy position plainly: **the token never leaves the machine except to `api.anthropic.com`; the app never writes or rotates credentials.** This is your strongest trust signal — say it on the page, not just in the README
- [ ] Optional: [[Sparkle]] for auto-updates (adds its own signing setup)

**Realistic effort:** one evening of work, plus waiting on the Developer Program.

---

## 3. Track B — Mac App Store ⛔ blocked

Three blockers. The first two are not code problems.

### 3.1 The credential model cannot survive the sandbox

MAS apps **must** be sandboxed. Every route to a token closes when you do that:

| Mechanism | What happens under the sandbox |
|---|---|
| `Credentials.fromKeychain()` spawning `/usr/bin/security` | Sandboxed apps cannot spawn arbitrary executables. Hits the existing `catch`, returns nil, fails silently |
| Keychain ACL on `"Claude Code-credentials"` | The ACL admits Claude Code's binary. A differently-signed app is not on it — password prompt or denial |
| `~/.claude/.credentials.json` via `temporary-exception.files.home-relative-path.read-only` | Temporary exceptions are a Developer ID accommodation. Not accepted at App Store review in practice, and "read another vendor's OAuth token" is not a justification that passes |

> [!danger] There is no entitlement that fixes this
> The feature *is* reading another application's stored credentials. That is
> precisely what the sandbox exists to prevent. Any MAS version needs a different
> way in — see [[Open questions]] below.

### 3.2 Trademark and a third-party private API

- Named **ClaudeMeter**; widget displays as *"Claude Code Usage"*
- Calls an **undocumented** endpoint — `api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`
- Uses **tokens issued to a different application**

Guideline 5.2 (Intellectual Property) territory: this needs written permission
from Anthropic before submission. Review also treats dependence on an
undocumented third-party service as a functionality risk on its own — your README
already flags it: *"Anthropic may change it."*

This applies to public distribution generally, **not only the App Store.** Worth
settling before Track A goes live too. See §5.

### 3.3 Mechanical gaps

All fixable, mostly shared with Track A:

- [ ] Real Team ID, distribution cert, provisioning profiles for app **and** appex
- [ ] `PrivacyInfo.xcprivacy` privacy manifest
- [ ] Replace the temporary file exception with a real `group.*` **App Group** — a Team ID makes this work, and it is what review expects. This also retires the `containermanagerd` workaround described in the README
- [ ] An Xcode project (MAS submission wants an archive; the CLT-only build has no path to one)
- [ ] Store metadata: screenshots, description, category, support URL

---

## 4. Sequencing

```
Apple Developer Program ($99)
        │
        ├──► Track A: Developer ID → notarize → website     ← do this
        │
        └──► Track B: needs Anthropic's permission FIRST,
                      then a token redesign, then Xcode project
```

Track A is the whole product, minus a storefront. Do not let Track B gate it.

---

## 5. Open questions

- [ ] **Ask Anthropic?** A short note asking about the name and the endpoint costs nothing and de-risks both tracks. Worth doing before the site goes live
- [ ] **Is there a sanctioned way to read usage?** If an official API or a documented token grant appears, Track B becomes possible. Without one it stays blocked
- [ ] **Rename?** If permission is refused, a non-infringing name distances it from Anthropic's marks — though it does not solve §3.1
- [ ] **Universal binary or Apple Silicon only?** Affects the download page copy
- [ ] **Auto-updates?** [[Sparkle]] is the standard answer for Developer ID apps

---

## 6. Product backlog — what to build next

Ordered by how much it changes what the app *tells* you. None of this is needed
for Track A; it is what the app should grow into once it ships.

### 6.1 The endpoint returns three things we ignore

Probed live on 2026-09-20. The response carries more than `Fetcher.parse` reads:

- [ ] **`seven_day_breakdown`** — where the weekly quota actually went, as
      percentages: `Claude Code 65% · Chats 35% · Cowork 0% · Other 0%`, with
      `window_started_at` and `as_of`. This is the one figure that tells you
      *what to stop doing*, and the large widget has the room. **Highest value
      item on this list.**
- [ ] **`limits[].severity`** (`"normal"` today) — the service's own threshold
      judgement, versus the hardcoded 75/90 in `UsageStyle.barColor`. Also
      `limits[].is_active`
- [ ] **`spend`** — a newer object paralleling `extra_usage`
      (`used.amount_minor` + `exponent`, vs `used_credits` + `decimal_places`).
      We parse only `extra_usage`; `spend` is the shape likelier to outlive it

### 6.2 Max plans are unrepresented

`Fetcher.parse` switches on `session` and `weekly_all` only. The schema also has
`seven_day_opus` / `seven_day_sonnet` (both null on this Pro account, so this is
untested against a real payload).

- [ ] Handle a `weekly_opus` row. On Max plans the Opus weekly limit is usually
      the *binding* one — those users currently see nothing about it

### 6.3 The app is passive

- [ ] **Threshold notifications** ("notify me at 80%"). The entire point of
      watching usage is not being surprised, and today you only find out by
      looking. Biggest user-facing gap that isn't a data gap
- [ ] **Menu bar shows session % only** — no way to glance at weekly, or at
      whichever of the two is higher. A preference, or just the larger figure

### 6.4 Correctness debt worth clearing first

- [ ] `Store.save` is load-modify-write with no cross-process lock. The
      snapshot/history merge papers over the common case, but two processes
      committing at once can still lose a field. Bounded today because the
      appex writes rarely; worth revisiting before adding more stored state
- [ ] No test suite at all. Three of the last five commits fixed bugs in
      `Fetcher`/`Store` state transitions that a dozen plain assertions over
      crafted `StoreState` JSON would have caught. A single `swiftc`-compiled
      test binary needs no Xcode and no Package.swift

---

## 7. References

- `CLAUDE.md` — build, architecture, invariants
- `README.md` §*Building a widget without Xcode* — the undocumented macOS requirements
- `Support/Widget.entitlements` — the sandbox exceptions at the centre of §3.1
- `build.sh` — signing lives at the bottom; Track A edits land there
- [[App Sandbox]] · [[Notarization]] · [[Developer ID Signing]] · [[WidgetKit]]
