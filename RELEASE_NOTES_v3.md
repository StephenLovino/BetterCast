# Release Notes - BetterCast v3.0

The smoothest, fastest BetterCast yet.

## ⚡️ Direct Peer-to-Peer Connection
In Version 3, we have completely re-engineered the connection layer. BetterCast now leverages **Apple's native direct peer-to-peer technology** (the same underlying tech used by AirDrop and Sidecar).

*   **No Router Needed**: Devices can communicate directly without relying on your home Wi-Fi router, significantly reducing latency and congestion.
*   **Real-Time Performance**: Experience a true real-time extension of your desktop with minimal lag.
*   **Enhanced Smoothness**: We've tuned the streaming to be buttery smooth, utilizing our new "Adaptive Pacing" engine to handle high-motion content flawlessly.

## 🛠️ Update Instructions
1.  **Download** the new zip file attached to this release.
2.  **Replace** your existing `BetterCastSender.app` and `BetterCastReceiver.app` in your Applications folder.
3.  **Important**: Run the terminal bypass command again if macOS prompts you.

    ```bash
    xattr -cr /Applications/BetterCastSender.app
    xattr -cr /Applications/BetterCastReceiver.app
    ```

## ⚠️ Note
*   The connection is now fully automatic and favors the most direct path between devices.
*   Make sure both Macs have Wi-Fi and Bluetooth enabled for the peer-to-peer discovery to work optimally.
