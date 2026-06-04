# iOS 12 Legacy Receiver — Support Plan

**Status:** Planned, not started (parked 2026-06-03)
**Goal:** Let an iPad mini 2 (A7, max **iOS 12.5.7**) run BetterCast as a **receiver**, distributed as a **separate sideloaded IPA** — no App Store.
**Origin:** GitHub request from `leandropaganello` (iPad mini 2, iOS 12.5.7).

---

## Feasibility — confirmed ✅

| Check | Result |
|---|---|
| Toolchain | Xcode 26.2 / iOS 26.2 SDK. SDK `MinimumDeploymentTarget = 12.0`, `SwiftOSRuntimeMinimumDeploymentTarget = 12.2`. So building for iOS 12 **is allowed**. |
| Device vs Swift floor | Device is **12.5.7 ≥ 12.2** → Swift runtime runs. ✅ |
| Concurrency | **No** async/await, no Combine, no actors in the receiver core (the `@MainActor init?(coder:)` are SwiftUI boilerplate; `networkQueue.async` is GCD). `SwiftConcurrencyMinimumDeploymentTarget = 15.0` is therefore not hit. ✅ |
| Launch model | Classic `AppDelegate` + `UIWindow`, **no UIScene/SceneDelegate**, no scene manifest → iOS 12 compatible. ✅ |
| Frameworks | Network.framework (NWListener/NWConnection, `includePeerToPeer`), VideoToolbox decode, `AVSampleBufferDisplayLayer`, AVAudioSession — all iOS 12+. ✅ |
| Core video screen | `ViewController` is **not** `@available`-gated; its only iOS-15 calls are cosmetic tab-bar show/hide already wrapped in `if #available(iOS 15, *)` (no-op on iOS 12). Can act as a standalone root. ✅ |

## The gotcha ⚠️

The current UI uses **unguarded iOS-13 APIs that crash on iOS 12** (unrecognized selector):
- `overrideUserInterfaceStyle = .dark` — `ViewController.swift:37` (iOS 13)
- `UIImage(systemName:)` SF Symbols — `ViewController.swift` (~lines 120, 469, 500, 507, 514, 520, 525, 530) and `VideoRendererViewIOS.swift:50` (iOS 13)

These must be avoided/guarded on the iOS-12 path.

## iOS-15-gated UI (stays as-is, just not used on iOS 12)
- `BCTabBarController` — `@available(iOS 15.0)`, the nav shell + root.
- `OnboardingView`, `SettingsView`, `SetupGuideView` — SwiftUI, `@available(iOS 15.0)`.
- Launch flow: `AppDelegate.makeRootViewController()` → `OnboardingHostingController` (if not completed) else `BCTabBarController`.

## Two approaches

### A) Separate target (RECOMMENDED — strongest "don't break existing")
- Main App Store target stays at iOS 15; **shipping source untouched**.
- New target `BetterCastReceiverIOS-Legacy`, deployment target **12.0**.
- Compiles **only** core files + a new minimal UIKit `LegacyReceiverViewController`; **excludes** `ViewController`, `BCTabBarController`, and the 3 SwiftUI files.
- Cost: xcodeproj surgery to add a target; two targets to keep in sync.

### B) Single target (one IPA, simpler long-term)
- Lower the existing target's `IPHONEOS_DEPLOYMENT_TARGET` 15.0 → 12.0.
- Compiler now forces `#available(iOS 13, *)` guards around the existing `ViewController` SF-Symbol / `overrideUserInterfaceStyle` calls. Active branch = current code → **iOS 15+ behavior byte-for-byte identical**; `else` fallback only runs on iOS 12.
- `AppDelegate`: `if #available(iOS 15, *) { …onboarding/tab… } else { LegacyReceiverViewController() }`.
- Cost: edits to shipping `ViewController` (low risk, but it touches the working file).

**Decision pending:** A vs B. Leaning **A** (separate target) per the "don't break existing" priority.

## Implementation steps (either approach)
1. Set deployment target 12.0 on the legacy build (xcodeproj).
2. Write `LegacyReceiverViewController` — UIKit, iOS-12-safe (plain buttons/labels or bundled PNGs instead of SF Symbols; no `overrideUserInterfaceStyle`). Reuses `NetworkListenerIOS`, `VideoDecoder`, `VideoRendererViewIOS` (guard its one `systemName` image), `AudioPlayerIOS`, `InputEvent`.
3. Route the iOS-12 root to it (`#available` branch in AppDelegate for B; legacy target's own AppDelegate/root for A).
4. Compile the **modern** build to prove no regression; build the legacy IPA.
5. Smoke-test on iPhone (iOS 15+) for no regression; Stephen tests the IPA on the iPad mini 2.

## Signing / distribution reality
- No App Store. Sideload via:
  - **Paid dev cert:** register iPad mini 2 UDID → ad-hoc signed IPA (valid ~1 year), or
  - **Free Apple ID** via AltStore/Sideloadly (7-day resign).
- Cannot build a final signed IPA or test in this environment (no device, no simulator — Stephen tests on his own hardware). Code + project changes can be prepared; signing/export is Stephen's step.

## Notes
- iOS receiver is built via **xcodeproj** (not SwiftPM); xcodeproj does **not** include `Constants.swift` — don't use `BCConstants` in iOS source, inline literals.
