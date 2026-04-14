# BetterCast v8 — Release Notes

## Unified App, New Sidebar, Guided Tour & More

BetterCast sender and receiver are now a single app with a completely redesigned interface.

### Unified Sender + Receiver
- **One app, two modes** — BetterCast now includes both sender and receiver functionality. No more separate receiver app in the DMG.
- **Receiver in separate window** — When receiving a stream, video opens in its own resizable window alongside the main app. Supports fullscreen.
- **Auto-open/close** — The video window appears automatically when a sender connects and closes when they disconnect.

### Apple Music-Style Sidebar
- **Redesigned navigation** — The sidebar now uses Apple Music-inspired styling with tinted icons and text for the active tab, and a subtle matte highlight instead of the old solid blue fill.
- **Full-row tap targets** — Click anywhere in a sidebar row to navigate, not just on the text.

### Guided Onboarding Tour
- **Spotlight highlights** — A 7-step interactive tour walks new users through each section of the app, with a spotlight cutout that highlights the relevant sidebar item.
- **Replay anytime** — Missed something? Go to Settings > Controls > "Replay Tour" to restart the tour.

### In-App Update Checker
- **Automatic update detection** — BetterCast checks GitHub Releases on launch and shows a banner when a newer version is available.
- **Smart comparison** — Only prompts to update when the remote version is actually newer (numeric comparison), and shows "You're on the latest version" otherwise.
- **One-click download** — The update banner links directly to the GitHub release page.

### Report Issue
- **Bug reporting from the app** — New "Report Issue" button in the Logs view opens a pre-filled GitHub issue with your system info and recent logs automatically attached.

### In-App Changelog
- **What's New section** — Settings now includes a changelog showing highlights for each version, so you can see what changed at a glance.

### Display Overview
- **Live display thumbnails** — The Overview shows live preview thumbnails of connected displays, similar to macOS System Settings.
- **Arrange Displays** — Quick link to open macOS Display Settings for arranging your extended displays.
- **Direct connect** — Hit "Connect" on a discovered device right from the Overview without navigating to its detail page.

### Versioning & Distribution
- **Proper versioning** — Version now reads from Info.plist (8.0) and matches GitHub release tags (v8). No more internal build number confusion.
- **Signed & notarized DMG** — Ready for distribution with no Gatekeeper warnings.

### Bug Fixes
- Fixed UI lag when switching to the Receiver tab (pre-initialized singleton, moved DNS lookup off main thread)
- Fixed `swift build` incremental cache serving stale binaries during development

### Update Instructions
1. **macOS**: Download the DMG, open it, and drag BetterCast to `/Applications`.
2. **iOS**: No changes — existing TestFlight build continues to work.
3. **Android**: No changes — existing APK continues to work.
