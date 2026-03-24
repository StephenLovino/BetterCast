# BetterCast Desktop Receiver — Build Instructions

Cross-platform C++ receiver for Windows and Linux.

## Prerequisites

### Windows
1. **Qt 6.5+** — Install via [Qt Online Installer](https://www.qt.io/download-qt-installer)
   - Select: Qt 6.x → MSVC 2019/2022 64-bit, Qt OpenGL Widgets
2. **FFmpeg** — Install via [vcpkg](https://vcpkg.io/) or pre-built binaries
   ```powershell
   vcpkg install ffmpeg:x64-windows
   ```
3. **CMake 3.20+** — Included with Visual Studio or install separately
4. **Visual Studio 2022** (Community edition is fine) — C++ Desktop workload
5. **(Optional) Bonjour SDK** — For mDNS auto-discovery
   - Install [Bonjour SDK for Windows](https://developer.apple.com/bonjour/)

### Linux
1. **Qt 6.5+**
   ```bash
   sudo apt install qt6-base-dev qt6-opengl-dev  # Debian/Ubuntu
   ```
2. **FFmpeg**
   ```bash
   sudo apt install libavcodec-dev libavutil-dev libswscale-dev
   ```
3. **Avahi** (for mDNS)
   ```bash
   sudo apt install libavahi-compat-libdnssd-dev
   ```
4. **CMake 3.20+**
   ```bash
   sudo apt install cmake
   ```

## Build

### Windows (Visual Studio)
```powershell
mkdir build && cd build

# If using vcpkg for FFmpeg:
cmake .. -DCMAKE_PREFIX_PATH="C:/Qt/6.7.0/msvc2019_64" ^
         -DCMAKE_TOOLCHAIN_FILE="C:/vcpkg/scripts/buildsystems/vcpkg.cmake" ^
         -DBONJOUR_SDK_HOME="C:/Program Files/Bonjour SDK"

cmake --build . --config Release
```

### Linux
```bash
mkdir build && cd build
cmake ..
cmake --build . -j$(nproc)
```

### macOS (for development/testing only)
```bash
brew install qt@6 ffmpeg
mkdir build && cd build
cmake .. -DCMAKE_PREFIX_PATH=$(brew --prefix qt@6)
cmake --build .
```

## Usage

1. Run `BetterCastReceiver` on the Windows/Linux machine
2. On the Mac sender, the receiver should appear via Bonjour auto-discovery
3. If auto-discovery doesn't work, use manual connect:
   - Enter the Mac sender's IP and port (default: 51820) in the receiver UI
   - Click "Connect"

## Architecture

```
main.cpp            → App entry point, OpenGL setup
MainWindow          → Qt window with connect UI + video display
NetworkListener     → TCP/UDP networking (same protocol as Swift receiver)
VideoDecoder        → FFmpeg H.264 decode (hardware accelerated when available)
VideoRenderer       → OpenGL YUV→RGB rendering with aspect-ratio letterboxing
InputHandler        → Mouse/keyboard capture → normalized coordinates → JSON
ServiceDiscovery    → mDNS advertising (Bonjour on Windows, Avahi on Linux)
InputEvent          → Data model matching Swift InputEvent exactly
```
