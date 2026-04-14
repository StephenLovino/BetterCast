# BetterCast

BetterCast is an open-source screen extension app that turns almost any device into a wireless extra display for your Mac. Think Sidecar or AirPlay Receiver — but cross-platform and built for hardware Apple no longer supports.

## How It Works

- **BetterCast Sender** runs on your primary Mac and creates a virtual display that streams over your network.
- **BetterCast Receiver** runs on the device you want to use as the extra screen.

Each receiver gets its own virtual display with independent resolution, input handling, and optional audio streaming.

## Supported Platforms

| Platform | Role | Connection | Download |
|----------|------|------------|----------|
| **macOS** | Sender + Receiver | P2P Direct / WiFi | [bettercast.online](https://bettercast.online/#install) |
| **iOS / iPadOS** | Receiver | P2P Direct (AWDL) / WiFi | [bettercast.online](https://bettercast.online/#install) |
| **Windows** | Receiver | WiFi | [GitHub Actions artifact](../../actions/workflows/build-windows-receiver.yml) |
| **Linux** | Receiver | WiFi | [GitHub Actions artifact](../../actions/workflows/build-linux-receiver.yml) |
| **Android** | Receiver | WiFi / ADB USB | [bettercast.online](https://bettercast.online/#install) |

> The macOS DMG is notarized and signed with an Apple Developer certificate.

## Features

- **Multi-device** — Connect multiple receivers simultaneously, each with its own virtual display
- **Cross-platform input** — Mouse and keyboard pass-through from any receiver back to the Mac
- **Audio streaming** — Optional per-device AAC-LC audio forwarding (128 kbps stereo)
- **Adaptive quality** — Per-link tuning: AWDL P2P runs 60 FPS at full bitrate; WiFi infrastructure runs 30 FPS at the user-selected bitrate (default 20 Mbps) with shorter keyframe intervals for faster recovery on lossy links; ADB tunnels match P2P quality
- **Zero-config for Apple devices** — iOS/Mac receivers are discovered automatically via AWDL (no WiFi network needed)
- **mDNS discovery** — Windows/Linux/Android receivers are discovered automatically when on the same network

## Installation

### macOS (Sender + Receiver)

1. Download the latest DMG from [bettercast.online](https://bettercast.online/#install)
2. Open the DMG and drag both apps to your Applications folder
3. Launch **BetterCastSender** and grant the required permissions:
   - **Screen Recording** — to capture your display
   - **Accessibility** — to relay mouse and keyboard input from receivers

### iOS / iPadOS

The iOS receiver is available via TestFlight. Visit [bettercast.online](https://bettercast.online/#install) for the install link.

### Windows

Download the latest build artifact from [GitHub Actions](../../actions/workflows/build-windows-receiver.yml). Extract and run `BetterCastReceiver.exe`. Both devices must be on the same WiFi network.

### Linux

Download the latest AppImage from [GitHub Actions](../../actions/workflows/build-linux-receiver.yml). Make it executable (`chmod +x`) and run. Both devices must be on the same WiFi network.

### Android

Visit [bettercast.online](https://bettercast.online/#install) for the latest APK. Supports WiFi and USB via ADB tunnel.

## Networking

BetterCast uses **TCP (port 51820)** for the primary video/audio stream and **UDP (port 51821)** for chunked frame delivery. Service discovery uses mDNS (`_bettercast._tcp`).

- **Apple-to-Apple**: Uses AWDL (Apple Wireless Direct Link) for a direct P2P connection — no WiFi router needed
- **All other platforms**: Requires both devices to be on the same WiFi/LAN network
- **Hotspot**: If no shared network is available, create a hotspot on any device and connect the Mac to it

### Wire Protocol

Frames are sent as length-prefixed TCP messages with a 1-byte type tag:

```
[4-byte big-endian length] [1-byte type] [payload]
  type 0x01 = H.264 video (AVCC NALUs, no Annex B start codes)
  type 0x02 = AAC-LC audio (raw frames, no ADTS header)
```

Legacy receivers (pre-1.3 iOS / Mac Swift) use a different framing without the type byte; the desktop receiver auto-detects the format on the first frame of each connection.

## Support the Project

BetterCast is free and open source. If you find it useful and want to support development, you can donate here:

**[Donate on Whop](https://whop.com/bettercast/bettercast-donate/)**

## Disclaimer

**USE AT YOUR OWN RISK.**

This software is provided "as is", without warranty of any kind, express or implied. We are not responsible for any damages to your devices, data loss, or other issues that may occur while using this application.

BetterCast is fully open source. We encourage users to audit the code for safety and security. If you find any issues, please report them or contribute a fix.

## License & Contribution

BetterCast is licensed under the **GNU General Public License v3.0 (GPLv3)**.

### Why GPLv3?
We believe in the freedom of software and the collective benefit of open collaboration. We choose GPLv3 to specifically:
- **Prevent restrictive forks**: Anyone who modifies and distributes this code must also share their changes under the same license. You cannot take this open source project, modify it, and sell it as a closed-source product.
- **Encourage contribution**: We welcome contributions! By keeping the source open, we ensure that improvements benefit everyone.

We strongly encourage safety and transparency. If you are contributing, please ensure your code adheres to safety standards and respects user privacy.
