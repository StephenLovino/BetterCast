cmake_minimum_required(VERSION 3.20)
project(BetterCastReceiver VERSION 17.0.0 LANGUAGES CXX)

# The Windows app's own version. Windows releases are tagged windows-<x.y.z>,
# a line of their own beside the macOS vNN tags, and on Windows this is the
# version the app reports and the update checker compares. CI reads the
# installer version from this line too - keep it on one line in this form.
set(BETTERCAST_WINDOWS_VERSION 1.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Sender mode (screen capture + encode + stream)
option(ENABLE_SENDER "Enable sender mode (screen capture + H.264 encode)" OFF)

# Qt6 components
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network OpenGLWidgets Multimedia)

# FFmpeg — try multiple discovery methods
# 1. vcpkg / CMake find_package (works on Windows CI)
# 2. pkg-config (works on Linux / macOS with brew)
# 3. Manual FFMPEG_ROOT path

set(FFMPEG_FOUND FALSE)

# Method 1: vcpkg provides FFmpeg as a single package
find_package(FFMPEG QUIET)
if(FFMPEG_FOUND)
    message(STATUS "FFmpeg found via find_package (vcpkg)")
    message(STATUS "  FFMPEG_INCLUDE_DIRS: ${FFMPEG_INCLUDE_DIRS}")
    message(STATUS "  FFMPEG_LIBRARIES: ${FFMPEG_LIBRARIES}")
    message(STATUS "  FFMPEG_LIBRARY_DIRS: ${FFMPEG_LIBRARY_DIRS}")
    set(FFMPEG_ALL_INCLUDE_DIRS ${FFMPEG_INCLUDE_DIRS})
    set(FFMPEG_ALL_LIBRARIES ${FFMPEG_LIBRARIES})
    # Some vcpkg versions return bare lib names — also set library dirs
    if(FFMPEG_LIBRARY_DIRS)
        set(FFMPEG_ALL_LIBRARY_DIRS ${FFMPEG_LIBRARY_DIRS})
    elseif(DEFINED VCPKG_INSTALLED_DIR)
        set(FFMPEG_ALL_LIBRARY_DIRS "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib")
    elseif(EXISTS "C:/vcpkg/installed/x64-windows/lib")
        set(FFMPEG_ALL_LIBRARY_DIRS "C:/vcpkg/installed/x64-windows/lib")
    endif()
else()
    # Method 2: pkg-config
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(AVCODEC libavcodec)
        pkg_check_modules(AVUTIL libavutil)
        pkg_check_modules(SWSCALE libswscale)
        if(AVCODEC_FOUND AND AVUTIL_FOUND AND SWSCALE_FOUND)
            message(STATUS "FFmpeg found via pkg-config")
            set(FFMPEG_FOUND TRUE)
            set(FFMPEG_ALL_INCLUDE_DIRS ${AVCODEC_INCLUDE_DIRS} ${AVUTIL_INCLUDE_DIRS} ${SWSCALE_INCLUDE_DIRS})
            set(FFMPEG_ALL_LIBRARY_DIRS ${AVCODEC_LIBRARY_DIRS} ${AVUTIL_LIBRARY_DIRS} ${SWSCALE_LIBRARY_DIRS})
            set(FFMPEG_ALL_LIBRARIES ${AVCODEC_LIBRARIES} ${AVUTIL_LIBRARIES} ${SWSCALE_LIBRARIES})
        endif()
    endif()
endif()

# Method 3: Manual path
if(NOT FFMPEG_FOUND AND DEFINED FFMPEG_ROOT)
    message(STATUS "FFmpeg using manual FFMPEG_ROOT=${FFMPEG_ROOT}")
    set(FFMPEG_FOUND TRUE)
    set(FFMPEG_ALL_INCLUDE_DIRS "${FFMPEG_ROOT}/include")
    set(FFMPEG_ALL_LIBRARY_DIRS "${FFMPEG_ROOT}/lib")
    set(FFMPEG_ALL_LIBRARIES avcodec avutil swscale)
endif()

if(NOT FFMPEG_FOUND)
    message(FATAL_ERROR "FFmpeg not found. Install via vcpkg, package manager, or set -DFFMPEG_ROOT=<path>")
endif()

# Platform-specific mDNS
if(WIN32)
    # Bonjour SDK for Windows (set via -DBONJOUR_SDK_HOME=...)
    if(DEFINED BONJOUR_SDK_HOME)
        set(MDNS_INCLUDE_DIRS "${BONJOUR_SDK_HOME}/Include")
        if(CMAKE_SIZEOF_VOID_P EQUAL 8)
            set(MDNS_LIBRARY_DIRS "${BONJOUR_SDK_HOME}/Lib/x64")
        else()
            set(MDNS_LIBRARY_DIRS "${BONJOUR_SDK_HOME}/Lib/Win32")
        endif()
        set(MDNS_LIBRARIES dnssd)
    endif()
elseif(UNIX AND NOT APPLE)
    # Linux: Avahi via pkg-config
    if(PkgConfig_FOUND)
        pkg_check_modules(AVAHI avahi-client)
        pkg_check_modules(AVAHI_COMPAT avahi-compat-libdns_sd)
        if(AVAHI_COMPAT_FOUND)
            set(MDNS_INCLUDE_DIRS ${AVAHI_COMPAT_INCLUDE_DIRS})
            set(MDNS_LIBRARY_DIRS ${AVAHI_COMPAT_LIBRARY_DIRS})
            set(MDNS_LIBRARIES ${AVAHI_COMPAT_LIBRARIES})
        endif()
    endif()
endif()

set(SOURCES
    main.cpp
    MainWindow.cpp
    DonatePrompt.cpp
    Language.cpp
    UpdateChecker.cpp
    Theme.cpp
    DisplayArrangement.cpp
    NetworkListener.cpp
    VideoDecoder.cpp
    VideoRenderer.cpp
    VideoWindow.cpp
    InputHandler.cpp
    ServiceDiscovery.cpp
    AudioDecoder.cpp
    AudioPlayer.cpp
    AdbHelper.cpp
)

set(HEADERS
    MainWindow.h
    DonatePrompt.h
    LogManager.h
    Language.h
    UpdateChecker.h
    Theme.h
    DisplayArrangement.h
    Icons.h
    NetworkListener.h
    VideoDecoder.h
    VideoRenderer.h
    VideoWindow.h
    InputHandler.h
    InputEvent.h
    ServiceDiscovery.h
    AudioDecoder.h
    AudioPlayer.h
    AdbHelper.h
)

# Windows Mobile Hotspot control. Not sender-only: a receiver may want to host
# the network too, and it is useless everywhere else.
if(WIN32)
    list(APPEND SOURCES HotspotManager.cpp GlassBackdrop.cpp thirdparty/qrcodegen.cpp)
    list(APPEND HEADERS HotspotManager.h GlassBackdrop.h QrImage.h thirdparty/qrcodegen.hpp)

    # This one file compiles as C++20 while the rest of the project stays on 17.
    #
    # C++/WinRT's base.h reaches for coroutine support, and under /std:c++17 that
    # means <experimental/coroutine>, which current MSVC refuses outright:
    #   "error STL1011: ... deprecated by Microsoft and will be REMOVED SOON".
    # C++20 routes it to the standard <coroutine> instead. Silencing the error
    # with _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS would only defer
    # the same break, and raising the whole project to C++20 is a far wider
    # change than one WinRT wrapper justifies.
    if(MSVC)
        set_source_files_properties(HotspotManager.cpp PROPERTIES
            COMPILE_OPTIONS "/std:c++20")
    endif()
endif()

# Sender mode sources
if(ENABLE_SENDER)
    list(APPEND SOURCES
        sender/VideoEncoderFF.cpp
        sender/NetworkSender.cpp
        sender/SenderController.cpp
    )
    list(APPEND HEADERS
        sender/ScreenCapture.h
        sender/VideoEncoderFF.h
        sender/NetworkSender.h
        sender/SenderController.h
    )
    if(WIN32)
        list(APPEND SOURCES
            sender/ScreenCaptureWin.cpp
            sender/VirtualDisplayVDD.cpp
            sender/InputInjector.cpp
        )
        list(APPEND HEADERS
            KeyCodeMap.h
            sender/InputInjector.h
            sender/ScreenCaptureWin.h
            sender/VirtualDisplayVDD.h
        )
    endif()
    # TODO: Linux PipeWire capture
endif()

# Qt resource file (embeds app icon PNG)
qt_add_resources(RESOURCES resources.qrc)

# Windows .exe icon via resource file
if(WIN32 AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/appicon.ico")
    list(APPEND SOURCES app.rc)
endif()

add_executable(BetterCastReceiver ${SOURCES} ${HEADERS} ${RESOURCES})

target_include_directories(BetterCastReceiver PRIVATE
    ${FFMPEG_ALL_INCLUDE_DIRS}
)

# One source of truth for the version. It used to be spelled out separately in
# this file, in main.cpp and in the CI makensis line, and they had already
# drifted: the app reported 1.0.0 while the published release said 1.0.1. The
# update checker compares against exactly this, so a drift would make it lie.
if(WIN32)
    set(BETTERCAST_APP_VERSION "${BETTERCAST_WINDOWS_VERSION}")
else()
    set(BETTERCAST_APP_VERSION "${PROJECT_VERSION}")
endif()
target_compile_definitions(BetterCastReceiver PRIVATE
    BETTERCAST_VERSION="${BETTERCAST_APP_VERSION}"
)

if(DEFINED FFMPEG_ALL_LIBRARY_DIRS)
    target_link_directories(BetterCastReceiver PRIVATE
        ${FFMPEG_ALL_LIBRARY_DIRS}
    )
endif()

target_link_libraries(BetterCastReceiver PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::OpenGLWidgets
    Qt6::Multimedia
    ${FFMPEG_ALL_LIBRARIES}
)

# mDNS support (optional — manual connect works without it)
if(DEFINED MDNS_LIBRARIES)
    target_compile_definitions(BetterCastReceiver PRIVATE HAS_MDNS=1)
    target_include_directories(BetterCastReceiver PRIVATE ${MDNS_INCLUDE_DIRS})
    target_link_directories(BetterCastReceiver PRIVATE ${MDNS_LIBRARY_DIRS})
    target_link_libraries(BetterCastReceiver PRIVATE ${MDNS_LIBRARIES})
endif()

# Sender mode compile definition and link flags
if(ENABLE_SENDER)
    target_compile_definitions(BetterCastReceiver PRIVATE ENABLE_SENDER=1)
    if(WIN32)
        # user32: CCD display-topology APIs (QueryDisplayConfig / SetDisplayConfig)
        # winmm:  timeBeginPeriod, for capture-thread timing granularity
        target_link_libraries(BetterCastReceiver PRIVATE d3d11 dxgi setupapi user32 winmm)
    endif()
endif()

# Windows-specific settings
if(WIN32)
    # dwmapi:      Mica backdrop and the dark/light title bar
    # windowsapp:  C++/WinRT umbrella import lib, for NetworkOperatorTetheringManager
    target_link_libraries(BetterCastReceiver PRIVATE ws2_32 dwmapi windowsapp)
    set_target_properties(BetterCastReceiver PROPERTIES WIN32_EXECUTABLE TRUE)
endif()

# UI translations, compiled into the binary as resources.
#
# Optional on purpose: lrelease ships in Qt's LinguistTools, which is a
# separate aqtinstall module. A developer without it should still get a
# working English build rather than a configure error, so a missing
# LinguistTools only costs the translations.
# CI sets this so a missing lrelease fails loudly. Without it, the optional
# path below would quietly ship an English-only build and the first anyone
# would know is a user asking why the language picker does nothing.
option(REQUIRE_TRANSLATIONS "Fail the build if translations cannot be compiled" OFF)

find_package(Qt6 QUIET COMPONENTS LinguistTools)
if(NOT Qt6LinguistTools_FOUND AND REQUIRE_TRANSLATIONS)
    message(FATAL_ERROR
        "Qt LinguistTools not found, but REQUIRE_TRANSLATIONS=ON. "
        "lrelease ships in the base Qt 6 desktop install; if it is genuinely "
        "absent the Qt install step needs fixing, not this check.")
endif()
if(Qt6LinguistTools_FOUND)
    qt_add_translations(BetterCastReceiver
        TS_FILES
            translations/bettercast_es.ts
            translations/bettercast_fil.ts
        RESOURCE_PREFIX "/i18n"
    )
    message(STATUS "Translations enabled (es, fil)")
else()
    message(STATUS "Qt LinguistTools not found - building English only")
endif()

# Install
install(TARGETS BetterCastReceiver RUNTIME DESTINATION bin)
install(FILES icon_256x256.png DESTINATION share/icons/hicolor/256x256/apps RENAME bettercast-receiver.png OPTIONAL)

# Install .desktop file directory (created at build time by CI)
install(DIRECTORY DESTINATION share/applications)
