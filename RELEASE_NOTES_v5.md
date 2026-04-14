# Release Notes - BetterCast v5.0
ProMotion & Performance.
This release brings significant engine improvements for higher refresh rates and smarter display handling.

⚡ **ProMotion & 120Hz Optimization**
BetterCast now feels as smooth as a native display on modern high-refresh hardware.
- **High Refresh Rate**: Added support for up to 120Hz streaming for ProMotion-capable Macs.
- **Jitter Reduction**: Increased buffer depth and optimized frame pacing for rock-solid visual stability.

🛠️ **Reliability Improvements**
- **Smarter Discovery**: Improved display discovery with intelligent retry logic to eliminate race conditions on startup.
- **Main Display Fallback**: BetterCast now gracefully falls back to your main display if a virtual display fails to initialize.
- **Permission Guidance**: Clearer in-app instructions for Screen Recording and Accessibility permissions.

📱 **BetterCast for iOS (In the Works)**
We are hard at work bringing BetterCast to the iPad and iPhone.
- **Engine Ready**: The v5 core includes a new, highly optimized mobile-ready engine.
- **Advanced Gestures**: Support for pinch-to-zoom, two-finger rotation, and smart zoom is baked in and will be available once the iOS app launches.
- **Status Update**: Official iOS client is in final testing—stay tuned for the IPA release!

📦 **Update Instructions**
1. **Download**: Grab the latest `.dmg` file.
2. **Install**: Open the DMG and drag both **BetterCastSender** and **BetterCastReceiver** to your `/Applications` folder.
3. **Open Anyway**: Since the apps are ad-hoc signed, macOS will block the first launch. 
    - Go to **System Settings > Privacy & Security**.
    - Scroll down and click **"Open Anyway"** for each app.
    - Confirm the prompt.
4. **Permissions**: Ensure you grant **Screen Recording** and **Accessibility** permissions on first launch.
