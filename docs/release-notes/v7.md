# BetterCast v92 — Release Notes

## Android Mirror Mode (Screen Cast Android → Mac)

Cast your Android screen to your Mac — like scrcpy, built directly into the BetterCast Android app.

### New Features
- **Android Sender Mode** — The Android app now has a Receive/Send toggle. Switch to "Send" mode to cast your Android screen to your Mac.
- **One-Click ADB Connection** — Mac receiver has a new "Connect to Android (ADB)" button that automatically runs `adb forward` and connects. Supports multiple devices (prefers USB over WiFi).
- **Remote Input Control** — Control your Android device from your Mac:
  - Click to tap
  - Trackpad scroll to swipe
  - Right-click for Back button
  - Keyboard input (Enter, Delete, Escape, arrows, volume, etc.)
- **H.264 Hardware Encoding** — Uses Android's MediaCodec hardware encoder for efficient screen capture at up to 1280p, 8Mbps, 30fps.
- **Foreground Service** — Screen capture stays alive in the background via a persistent notification.

### How to Use
1. Install the APK on your Android device
2. Open the app, switch to **Send** mode, tap **Start Casting**
3. Grant screen capture permission when prompted
4. On your Mac, open **BetterCast Receiver** and click **Connect to Android (ADB)**
5. Your Android screen appears on your Mac

### Known Limitations
- Requires ADB (Android SDK) installed on your Mac
- USB connection recommended (WiFi ADB works but may have latency)
- Mac receiver window does not yet auto-resize when the Android device changes orientation mid-stream (restart casting to pick up new orientation)
- Remote input via `adb shell input` has slight latency (~100ms per command)

### Bug Fixes
- Fixed scroll input flooding device with rapid swipe commands (now throttled)
- Fixed port conflict when switching between Receive and Send modes
- Fixed multi-device ADB support (no longer fails with multiple devices attached)
