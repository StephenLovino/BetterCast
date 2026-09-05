# Windows glass UI — where this is up to

Written to be picked up on another machine. The code is all on
`fix/windows-sender-latency-topology`; this is the part that is not in the code.

Last updated at commit `d6ee3d2`, 19 Aug 2026.

## What this is

`spike/` holds a second Windows front end, built on
[liquidDX11](https://github.com/StephenLovino/liquidDX11) — a Dear ImGui + D3D11
glass UI. It is not a rewrite. liquidDX11's own tree is copied in CI and only
the page bodies, the nav labels and a handful of anchored lines in its
`main.cpp` are changed, each patch asserting that it applied. The BetterCast
core is compiled into that same target and driven in-process:

- `spike/glass-app/BetterCastBridge.{h,cpp}` — the seam. Creates a real
  `QApplication`, pumps it once per render frame, and exposes the core through
  plain types so the ImGui page fragments never see Qt.
- `spike/glass-ui/pages/*.inc` — page bodies overlaid onto liquidDX11's.
- `.github/workflows/build-glass-spike.yml` — the overlay, the patches, the
  CMake append, and now the installer.

Two things had to be true first, and both are: the core is widget-free
(`LogManager` was lifted out of `MainWindow.h`), and a full `QApplication` keeps
the existing `VideoWindow` working, so the receive path needed no porting.

The Qt app in `Sources/BetterCastReceiverDesktop` still builds and ships
unchanged. Both are installed side by side.

## Confirmed working on real hardware

Display pool with three simultaneous receivers; Mobile Hotspot and QR pairing
(all three receivers plus the Mac's scanner); per-device resolution; the update
checker; language switching; the glass front end streaming at 4% integrated GPU
/ 0% discrete, down from ~50%; DXGI duplication coexisting with the Qt app; the
receive path.

## Open work

**Needs a macOS session.** Two things cannot be finished from Windows:

1. **Answering "extend/mirror your screen onto this PC".** The Windows half is
   written and shipping; the Mac half is not, and until it exists the two
   buttons draw disabled with an explanation. See below.
2. Audio playback on the Mac side.

### The Mac half of "ask that device for its screen"

The Windows side sends, to TCP **51822** on the sender, one
`[4B big-endian length][JSON]` frame:

```json
{ "type": 99, "keyCode": 770, "deviceName": "STUDIO-PC (Windows)",
  "mode": "extend", "port": 51820 }
```

and expects, on the same connection, one framed reply identifying the app:

```json
{ "app": "BetterCast", "ok": true }
```

**The reply is not optional.** Without it Windows treats the device as unable
to answer, and the buttons stay disabled. That is deliberate: the first version
took "the TCP connection was accepted" as proof, something unrelated on the Mac
accepts on 51822, and the buttons enabled themselves and sent four requests
into a process that had never heard of BetterCast.

`mode` is also `probe`, which means identify yourself and start nothing — that
is what the enabled/disabled state is decided by.

`type` 99 is `InputEventType.command` and `keyCode` 770 is a device hello —
the shape `InviteListener` on the Windows side already accepts, so both ends
of this protocol are the same format. `mode` is `extend` or `mirror`. `port`
is where to dial back, named rather than assumed so a receiver that fell back
to another port is still reachable.

What the Mac needs, all in `BetterCastSenderApp.swift`, and small because both
switches it has to flip already exist:

1. An `NWListener` on 51822 that reads one length-prefixed JSON frame.
2. On a frame with `type == 99 && keyCode == 770`: reply
   `{"app":"BetterCast","ok":true}` framed the same way — **always**, including
   for `mode == "probe"`, which is how Windows decides whether to offer the
   buttons at all. Then, unless the mode is `probe`, set `useVirtualDisplay`
   from it (`extend` → `true`, `mirror` → `false`) and call `connect(to:)` for
   the peer that sent it, at the `port` it named.

`connect(to:)` and `useVirtualDisplay` (line ~2250) are exactly what the
Auto-Connect path already drives, so this is wiring, not new streaming code.

**What works today without any of this:** turn on **Auto-Connect** in the Mac
sender and set **Use as** to Extended Display or Mirror Built-in. `autoConnect`
(line ~2371) calls `connect(to:)` for every newly discovered receiver, so the
Mac starts sending to Windows as soon as Windows appears. The difference is
that it applies to every receiver and is controlled from the Mac.

Note: no client anywhere in this repo sends the 770 hello — not iOS, not
Android, not macOS. The format was designed on the Windows side for
`InviteListener` (on `fix/android-windows-discovery`, unmerged) and the Windows
sender above is its first user. Nothing else depends on it, so it can still be
changed freely.

**Windows-side, not started.**

- No outgoing audio at all. `NetworkSender::sendAudio()` exists and nothing
  calls it; Windows has no loopback capture. Needs WASAPI plus an AAC encoder.
  Incoming audio from the Mac does work.
- Hotspot and Receive pages are still liquidDX11's placeholders. Devices,
  Settings and the profile page are real.
- Double-logging in the glass build: every line appears twice, and the bridge's
  own lines appear once. Probably two `ServiceDiscovery`/`VirtualDisplayVDD`
  instances, or the Qt app running alongside and sharing `bettercast.log`.
  Observed, never investigated.

**Branch hygiene.** `fix/windows-sender-latency-topology` is ~72 commits ahead
of `main` and has never been merged. Five more commits are stranded on
`chore/security-policy`, `chore/windows-build-hardening` and
`fix/android-windows-discovery`.

## Things that have bitten more than once

- **`vdd_settings.xml` belongs to the driver, not to us.** BetterCast wrote a
  schema of its own invention — `<VirtualDisplaySettings><Displays><Display>
  <Width>` — and read that same shape back, so writer and reader agreed with
  each other and neither agreed with the Virtual Display Driver, which reads
  `<vdd_settings><resolutions><resolution><width>`. Nothing compared them
  against a real file until one was downloaded from the VDD release and opened.
  The overwrite also deleted `<monitors><count>`, which is how the driver knows
  how many monitors to create. Symptoms, none of which pointed at the cause:
  virtual displays stuck at 800×600 (the driver's first *stock* mode, because
  our list never reached it), then displays that would not attach at all, then
  device nodes piling up as the sender kept adding more looking for a free one.
  Fixed by copying the file through and replacing only `<resolutions>`. If you
  touch that file again, diff it against
  `SignedDrivers/x86/VDD/vdd_settings.xml` from the VDD release zip first.

- **A silent failure can be load-bearing.** The write above needs administrator
  rights and had been failing quietly for months, which left the driver's own
  file intact and the product half-working. Fixing that silent failure is what
  finally let the corruption land. When repairing something that fails
  silently, check what has been depending on it failing.

- **Write C++ and YAML with an editor, not a shell heredoc.** Backslashes and
  non-ASCII have been corrupted in transit at least six times — `'\\'` becoming
  `'\'`, literal `\n` landing in YAML, Spanish accents stripped out of
  translations twice.
- **Assert observable state, not return codes.** `Backdrop::Init` ignoring
  `CreateDuplication()`'s result is the archetype, and every CI patch now
  throws if its target string was not found.
- **`QFileInfo::isWritable()` lies on Windows.** It reads the read-only
  attribute, not the ACL, so the elevated settings write never ran. Attempt the
  write and fall back on failure.
- **`actions/checkout` gives CRLF on Windows.** Normalise before matching or
  any multi-line pattern silently fails.
- **A PowerShell here-string terminator sits at column 0**, and a column-0 line
  inside a YAML block scalar ends the block. Use an array joined with newlines.
- **`qttools` is not an aqt module** for Qt 6 desktop. `qtmultimedia` is.
- **Growing the virtual display pool restarts the driver** and kills every live
  capture, so the pool is built once, up front, while nothing is streaming.
