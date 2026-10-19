# Spec: fit the virtual display to any receiver screen

Status: to build in-house. Source: the problems reported in xercn's PRs #64 and #65
(Galaxy Z TriFold user). We are not merging that code. This spec describes the
problems and the behaviour we want, in our own terms, so we write our own
implementation. Keeping the sender sole-authored also keeps the open-core / Pro
licensing options open (see project_premium_strategy).

## Problems to solve

1. **Black bars on non-16:9 receivers.** Receivers that do not report their screen
   size (Android before 1.4, Windows, Linux) only get the 16:9 and 16:10 presets.
   A Galaxy Z TriFold unfolded is 2160x1584 (about 15:11), so it shows bars on both
   sides. Same for 3:2, 4:3 and near-square foldables.
2. **Bigger text costs sharpness.** The only way to make the UI larger today is to
   pick a lower resolution, which the receiver then upscales (blurry).
3. **Android ignores rotation.** The Android receiver always reports landscape and
   locks landscape. Some large-screen devices (One UI on foldables) ignore the
   app's orientation lock, so standing the device upright shows a landscape picture
   letterboxed into a portrait screen. Folding or unfolding changes the size too.
4. **The display jumps sides.** When the virtual display is rebuilt or resized
   (rotation, mode change), macOS treats it as new and may place it on the other
   side of the main screen from where the user arranged it.
5. **Reset Permissions uses a hardcoded bundle ID** (`com.bettercast.sender`), so it
   does nothing for builds with a different ID (dev builds). Trivial fix, do it now.

## Requirements

### R1. Custom resolution (Mac sender)
- Resolution picker gets a "Custom..." entry with width and height fields.
- Valid range 640 to 5120 per side; round down to even (encoders reject odd sizes).
- Persist across launches. Unknown saved sizes load as custom, not dropped.
- One shared picker view instead of the three duplicated pickers.

### R2. Per-device native resolution (Mac sender)
- Each device page shows a "Screen" section:
  - Device reports its size (command 777: iOS, iPadOS, Android 1.4+): show it, read-only.
  - Otherwise: let the user register a native resolution (same validation as R1),
    with Change and Remove, plus a Portrait toggle that swaps width and height.
- Key by the same per-device key used for reported sizes (`screenSizeKey`).
- When a native size is known, stream at exactly that size.

### R3. Text size without losing sharpness (Mac sender)
- For a device with a known native size, offer a "Text Size" picker, from
  "Larger Text" to "More Space". Each option is a HiDPI scaled mode of the
  virtual display; capture and streaming stay at the native pixel size.
- Switch live (no display rebuild, stream keeps running), save per device,
  and stay in sync if the user changes it in System Settings > Displays.
- Drop options whose short side would be under ~480 points.
- Open question: this makes those displays always HiDPI, even with Retina off.
  Check the backing buffer size on large panels (2x native at "More Space",
  e.g. 5464x4096 for a 12.9" iPad). Cap the factor list if creation fails or GPU
  memory is excessive. Decide whether the Retina toggle should still apply.

### R4. Android rotation (Android receiver)
- Setting under Display: Rotation = Landscape (default, today's behaviour),
  Portrait, Auto (follow the device, honour the system rotation lock).
- While streaming, re-send command 777 whenever the panel settles in a new shape
  (rotation, fold, unfold), reporting the size as actually shown, not as the lock
  assumes. Debounce (about 600 ms) so a quick back-and-forth sends one report.
- Do not report while in PiP (the window shape is not the panel).
- Must not cause a reconnect storm: verify the Mac rebuilds the display once per
  settled change, and that the Huawei / plain-decoder path still recovers.

### R5. Keep the display on its side (Mac sender)
- Remember each device's display placement (which side of the main screen).
- After a rebuild or mode change, put it back on the same side (right, left,
  above), aligned to the same edge.
- Do not record placement during our own transitions, only after the user or
  macOS settles it.

## Implementation rules (from our own crash history)
- Never write `pipelines` while iterating it. Snapshot first
  (`let targets = pipelines.filter { ... }.map(\.key)`), then write.
- Never touch `pipelines` from the encoder thread. New per-device state
  (native size, placement-pending flag) is written on main only.
- Delayed work (`asyncAfter`) must re-check that the same display ID is still
  live before acting.
- No new strings without all six locales (en, zh-Hans, ja, ko, de, fr).

## Acceptance tests
- Android phone registered at its native size: fills the screen, no bars, sharp.
- Text size changes apply instantly, persist after reconnect, and match
  System Settings.
- Large iPad over Wi-Fi at "More Space": display creates, no stutter.
- Android Auto mode: rotate, fold and unfold; the Mac display follows once each time.
- Display arranged to the right of the main screen stays on the right after
  rotating and after changing text size.
- Lenovo tablet and the Huawei (plain-decoder fallback) still connect.

## Suggested order
1. R1 and the bundle ID fix (small, ships in the next Mac release).
2. R4 (Android only, independent, reuses command 777).
3. R2 + R3 together.
4. R5.
