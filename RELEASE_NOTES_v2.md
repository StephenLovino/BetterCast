# Release Notes - BetterCast v2.0

We are stepping up the game with BetterCast v2! This release focuses on performance and standardizing the connection protocol.

## 🚀 Key Improvements
*   **Default UDP Connection**: We have switched the default transport protocol to UDP. This significantly improves realtime streaming performance, reducing latency and creating a much smoother experience.
*   **Enhanced Connectivity**: Logic for the connection has been optimized to ensure better stability and speed.

## 📦 Note on File Versioning
You may notice that the version numbers inside the downloadable ZIP files (e.g., `BetterCast_v40_Ultra.zip`) do not match the GitHub release version (v2.0).
*   **Why?** The internal filenames reflect our internal build and local test versions.
*   **Rest Assured**: The files attached to this release **ARE** the correct v2.0 binaries, regardless of the filename inside the zip.

## 🔮 Roadmap
We are working hard to expand BetterCast to more platforms!
*   **iPad Support**: In progress.
*   **Windows Receiver**: In progress.

## 🤝 Feedback & Issues
We want to hear from you! Since we are rapidly iterating:
*   **Report Issues**: If you encounter bugs or connection drops, please open an issue.
*   **Feature Requests**: Have an idea? Let us know!

---

## 🛠️ Step-by-Step Installation Guide

Since this is an open-source tool and not signed by Apple, you need to follow these exact steps to run it.

### Step 1: Download & Unzip
1.  Download the zip file attached to this release.
2.  Double-click it to find two apps: `BetterCastSender.app` and `BetterCastReceiver.app`.

### Step 2: Drag to Applications Folder (Important!)
You **must** move the apps to your Applications folder for the commands to work. 

*   **Primary Mac (The computer with the screen you want to share):**
    Drag `BetterCastSender.app` into your **Applications** folder.

*   **Secondary Mac (The older Mac you want to use as a screen):**
    Drag `BetterCastReceiver.app` into your **Applications** folder.

### Step 3: Run the Command
1.  Open the **Terminal** app (Command + Space, type "Terminal").
2.  Copy and paste the command below for the specific app you installed on that machine, then press **Enter**.

**On your Primary Mac (Sender):**
```bash
xattr -cr /Applications/BetterCastSender.app
```

**On your Secondary Mac (Receiver):**
```bash
xattr -cr /Applications/BetterCastReceiver.app
```

### Step 4: Launch!
Go to your Applications folder and open the app. It should now open successfully!
