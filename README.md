# BetterCast

BetterCast is an open-source application designed to breathe new life into older Macs. It allows you to use an older Mac as an extended display for your primary computer, a feature similar to Sidecar or AirPlay Receiver but tailored for hardware that Apple no longer supports for these features.

This is perfect for repurposing devices like non-Apple Silicon Macs that can no longer serve as Sidecar receivers, effectively giving you a high-quality extra screen for free.

## Installation & Usage

BetterCast is distributed as an unsigned application (ad-hoc signed). To run it, you need to bypass macOS Gatekeeper checks.

1.  **Download and Install**: Drag the `BetterCast.app` into your `/Applications` folder.
2.  **Authorize the App**: Open your Terminal and run the following command to remove the quarantine attribute:

    ```bash
    xattr -cr /Applications/BetterCast.app
    ```
3.  **Launch**: Open BetterCast from your Applications folder.

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
