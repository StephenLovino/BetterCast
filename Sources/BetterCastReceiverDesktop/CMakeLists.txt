cmake_minimum_required(VERSION 3.20)
project(BetterCastReceiver VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

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
    set(FFMPEG_ALL_INCLUDE_DIRS ${FFMPEG_INCLUDE_DIRS})
    set(FFMPEG_ALL_LIBRARIES ${FFMPEG_LIBRARIES})
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
    NetworkListener.cpp
    VideoDecoder.cpp
    VideoRenderer.cpp
    InputHandler.cpp
    ServiceDiscovery.cpp
    AudioDecoder.cpp
    AudioPlayer.cpp
)

set(HEADERS
    MainWindow.h
    NetworkListener.h
    VideoDecoder.h
    VideoRenderer.h
    InputHandler.h
    InputEvent.h
    ServiceDiscovery.h
    AudioDecoder.h
    AudioPlayer.h
)

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

# Windows-specific settings
if(WIN32)
    target_link_libraries(BetterCastReceiver PRIVATE ws2_32)
    set_target_properties(BetterCastReceiver PROPERTIES WIN32_EXECUTABLE TRUE)
endif()

# Install
install(TARGETS BetterCastReceiver RUNTIME DESTINATION bin)
