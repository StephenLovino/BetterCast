# Release Notes - BetterCast v6.0
Cross-Platform & TCP Reliability.
This release brings BetterCast to Android and Windows/Linux (via TCP), with major networking fixes for rock-solid connections.

📱 **Android Receiver**
BetterCast now works on Android devices.
- **Full Android Support**: A native Android receiver app joins the family alongside Mac and iOS.
- **Wireless Discovery**: Automatic Bonjour/mDNS discovery — your Android device finds the sender on the same WiFi network, just like Mac and iOS receivers.
- **ADB Wired Mode**: Connect your Android device via USB and stream over `localhost:51820` for zero-latency, zero-packet-loss streaming.
- **Low-Latency Decoding**: Hardware MediaCodec decoder with vendor-specific fast paths for minimal decode latency.

🔧 **TCP Streaming Overhaul**
TCP mode has been rebuilt from the ground up for reliable streaming over any network.
- **Heartbeat Protocol Fix**: Fixed a critical bug where the receiver's heartbeat corrupted the TCP stream, causing connections to drop after 15 seconds.
- **Interactive Video QoS**: TCP connections now use `.interactiveVideo` service class, telling macOS to prioritize streaming traffic over background downloads.
- **Nagle's Algorithm Disabled**: `TCP_NODELAY` enabled on all paths (sender, receiver, and ADB) to eliminate micro-buffering delays.
- **Matched Frame Rates**: The encoder and capture pipeline now share the same frame rate, eliminating glitchy video caused by dropping encoded P-frames.

🎨 **New App Icon**
- All platforms (Mac, iOS, Android) now feature the official BetterCast logo.

🌐 **Connection Defaults**
- **Force P2P (WiFi Direct)** is the default connection mode for the lowest latency Mac-to-Mac experience.
- **UDP** remains the recommended protocol for WiFi. TCP is ideal for wired/ADB connections.

📦 **Update Instructions**
1. **Download**: Grab the latest `.dmg` file.
2. **Install**: Open the DMG and drag both **BetterCastSender** and **BetterCastReceiver** to your `/Applications` folder.
3. **Open Anyway**: Since the apps are ad-hoc signed, macOS will block the first launch.
    - Go to **System Settings > Privacy & Security**.
    - Scroll down and click **"Open Anyway"** for each app.
    - Confirm the prompt.
4. **Permissions**: Ensure you grant **Screen Recording** and **Accessibility** permissions on first launch.
5. **Android (Wireless)**: Install the APK via `adb install app-debug.apk`. The app auto-discovers the sender on your WiFi network.
6. **Android (Wired/USB)**: For the lowest latency, use ADB port forwarding: `adb forward tcp:51820 tcp:51820`, then connect to `localhost:51820` in the sender.
