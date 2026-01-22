# BetterCast

BetterCast is an open-source application designed to breathe new life into older Macs. It allows you to use an older Mac as an extended display for your primary computer, a feature similar to Sidecar or AirPlay Receiver but tailored for hardware that Apple no longer supports for these features.

This project consists of two applications:
*   **BetterCastSender**: Runs on your primary Mac (the one you want to extend the screen *from*).
*   **BetterCastReceiver**: Runs on your older Mac (the one you want to use *as* the screen).

This is perfect for repurposing devices like non-Apple Silicon Macs that can no longer serve as Sidecar receivers, effectively giving you a high-quality extra screen for free.

## Installation & Usage

BetterCast is distributed as unsigned applications (ad-hoc signed). To run them, you need to bypass macOS Gatekeeper checks on the respective machines.

### 1. Download and Install
*   Drag **BetterCastSender.app** to the `/Applications` folder on your **primary Mac**.
*   Drag **BetterCastReceiver.app** to the `/Applications` folder on your **older/secondary Mac**.

### 2. Authorize the Apps
You must run the following command in Terminal to allow the apps to run.

**For BetterCastSender (Primary Mac):**
```bash
xattr -cr /Applications/BetterCastSender.app
```

**For BetterCastReceiver (Secondary Mac):**
```bash
xattr -cr /Applications/BetterCastReceiver.app
```

### 3. Launch
Open the respective app on each Mac to start the connection.

## Disclaimer

**USE AT YOUR OWN RISK.**

This software is provided "as is", without warranty of any kind, express or implied. We are not responsible for any damages to your devices, data loss, or other issues that may occur while using this application.

BetterCast is fully open source. We encourage users to audit the code for safety and security. If you find any issues, please report them or contribute a fix.

## License & Contribution

BetterCast is licensed under the **GNU General Public License v3.0 (GPLv3)**.

### Why GPLv3?
We believe in the freedom of software and the collective benefit of open collaboration. We choose GPLv3 to specifically:
*   **Prevent restrictive forks**: Anyone who modifies and distributes this code must also share their changes under the same license. You cannot take this open source project, modify it, and sell it as a closed-source product.
*   **Encourage contribution**: We welcome contributions! By keeping the source open, we ensure that improvements benefit everyone.

We strongly encourage safety and transparency. If you are contributing, please ensure your code adheres to safety standards and respects user privacy.
