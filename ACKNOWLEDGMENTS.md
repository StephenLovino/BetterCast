# Acknowledgments

BetterCast is original code, but several design decisions were informed by
studying other open-source projects. No source code from these projects is
included in BetterCast. The debt is one of ideas, and it deserves credit.

- [SideScreen](https://github.com/tranvuongquocdat/SideScreen) (MIT) —
  studying its streaming pipeline led directly to two of v18's improvements:
  applying flow control *before* the encoder rather than after it (so network
  congestion skips frames instead of corrupting the picture), and removing
  VideoToolbox's DataRateLimits cap on infrastructure Wi-Fi. BetterCast's
  per-second pipeline log format is deliberately shaped like SideScreen's so
  the two projects' diagnostics can be compared side by side.
- [targetBridge](https://github.com/swellweb/targetBridge) (MIT) by Marco
  Caciotti — the inspiration for BetterCast's 5K Retina profile and for
  treating "an old 5K iMac as a display over Thunderbolt" as a first-class
  use case.
- [scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0) — the
  repeat-previous-frame idea behind the static-content frame pump, and the
  ordered-queue decoding approach used by the Android receiver.
- [Moonlight](https://github.com/moonlight-stream) (GPL-3.0) — the Android
  MediaCodec low-latency vendor keys used by the Android receiver.
