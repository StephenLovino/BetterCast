# macOS Catalina (10.15) Receiver — Support Plan

**Status:** Planned, not started (parked 2026-06-06)
**Goal:** Let an old Intel Mac on **macOS 10.15 Catalina** (e.g. late-2012 iMac) run BetterCast as a **receiver** / second monitor for a modern Mac sender.
**Origin:** GitHub issue #33 (goodymusicstudio-cmyk — M3 Pro Sonoma → late-2012 iMac on Catalina).

---

## Feasibility — toolchain & core ✅
| Check | Result |
|---|---|
| SDK floor | macOS 26 SDK `MinimumDeploymentTarget = 10.13` → 10.15 is allowed. |
| Architecture | late-2012 iMac is **Intel x86_64** — covered by the universal build's x86_64 slice. |
| Receiver core | `ReceiverNetworkListener`, `ReceiverVideoDecoder`, `ReceiverVideoRenderer` use only GCD + Network.framework (NWListener 10.14+) + VideoToolbox (10.8+) + AVSampleBufferDisplayLayer (10.8+). **No async/await, no NWBrowser, no macOS-13 APIs.** Reusable on 10.15. |

## The wall ⛔ (why it's not a floor-lower like #31)
The current app cannot run below macOS 13 — and not because of a setting:
- **Entry point:** `@main struct BetterCastSenderApp: App` — the SwiftUI `App` protocol is `@available(macOS 11.0)`. **At a 10.15 deployment target this does not even compile.** Internal `#available` guards can't help; the app's *entry point* is too new.
- **UI shell:** `NavigationSplitView` (macOS 13+) and `.formStyle(.grouped)` (13+) — the entire sidebar UI.

So the effective floor of the current app is **13**, set by the UI + lifecycle, not by `LSMinimumSystemVersion`.

## Approach A — Single app, auto-detect by OS (avoid a separate app)
Re-found the app on the **AppKit lifecycle** so one binary can run 10.15 → 26:
1. Drop the SwiftUI `@main App`; use **`NSApplicationMain` + `AppDelegate`** (works on 10.15 and modern macOS).
2. In the AppDelegate, branch at runtime:
   - `if #available(macOS 13, *)` → host the existing SwiftUI `NavigationSplitView` UI via `NSHostingController` (modern app unchanged in behavior).
   - else (10.15–12) → a minimal **AppKit receiver UI** (an `NSWindow` hosting the video layer) wired to the 10.15-safe receiver core.
3. Set deployment target to 10.15; keep universal (arm64 + x86_64).

**Pros:** one app, "auto-detects" the OS — exactly the no-separate-app goal.
**Cons / risk:** this re-founds the **shipping app's entry point** (SwiftUI App → AppKit). High blast radius — real regression risk to the working modern app, and a meaningful refactor (window management, scene/menu setup, the tour/onboarding hosting, etc.). Also still needs the legacy AppKit UI for <13.

## Approach B — Separate minimal AppKit receiver app (lower risk)
A second, receiver-only target: `NSApplication` + one `NSWindow` + the existing receiver core, deployment target 10.15, Intel. No ScreenCaptureKit/sender code, so simpler.
**Pros:** **zero risk** to the shipping app; small and self-contained.
**Cons:** a second artifact to build/sign/distribute.

## Recommendation
For one 13-year-old Catalina machine, **Approach B (separate receiver) is the pragmatic, low-risk choice** — Approach A's lifecycle refactor endangers the working modern app for marginal benefit. If Catalina/Big-Sur/Monterey demand grows, revisit A (it's the "right" long-term answer: one app, OS-adaptive UI).

Either way: **receiver-only** for the old Mac (it's the 2nd monitor; the modern Mac is the sender). Needs a Catalina/Intel machine to test — not available in this environment.

## Notes
- Lowering the floor to 11 or 12 does NOT help — `NavigationSplitView` is 13+, so Big Sur/Monterey can't run the current UI either. Anything below 13 needs an alternative UI.
- Related: [[project_ios12_legacy]] (same shape: core is fine, only the modern UI shell blocks it), [[project_macos_floor]] (the 14→13 drop, which WAS a simple floor-lower).
