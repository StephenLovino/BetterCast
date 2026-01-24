# Release Notes - BetterCast v4.0

**Stability and Polish.**
This release brings BetterCast to a "native" level of reliability, comparable to Apple's own Sidecar.

## 📡 "Infrastructure-Free" Connection (AWDL 2.0)
We have significantly improved the direct peer-to-peer engine.
*   **Zero Interference**: The connection (using Apple Wireless Direct Link) is now isolated from your home Wi-Fi infrastructure. This means heavy downloading on your router won't lag your extended display.
*   **Rock Solid Stability**: Fixed issues where the connection would randomly drop or timeout. It now intelligently handles localized interference without disconnecting.
*   **Instant Linking**: Connection times are now near-instant, similar to Sidecar.

## ✨ Visual Polish
*   **No More "Black Streak"**: We have resolved the rendering bug that caused a distracting black line or streak on the edge of the display.
*   **Perfect Alignment**: The screen now fits perfectly edge-to-edge with correct aspect ratio handling.

## 📦 Update Instructions
1.  **Download** the new zip attached.
2.  **Replace** the existing apps in your `/Applications` folder.
3.  **Run the bypass command** if prompted:

    ```bash
    xattr -cr /Applications/BetterCastSender.app
    xattr -cr /Applications/BetterCastReceiver.app
    ```
