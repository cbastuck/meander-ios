cmake_minimum_required(VERSION 3.21)

# ── iOS platform settings ─────────────────────────────────────────────────────
# These MUST be cache variables set before project() so the Xcode generator
# picks up the right SDK and deployment target.
#
# Use the CMakePresets.json presets (recommended):
#
#   # Physical device (arm64-ios)
#   cmake --preset ios-device   (from repo root or meander-ios/)
#   open build/meander-ios-device/MeanderIOS.xcodeproj
#
#   # Simulator on Apple Silicon (arm64-ios-simulator)
#   cmake --preset ios-simulator
#   open build/meander-ios-simulator/MeanderIOS.xcodeproj
#
# The presets live in meander-ios/CMakePresets.json.
# Device and Simulator require separate build trees — they link against
# different vcpkg-built libraries (iphoneos vs iphonesimulator sysroot).

# Provide defaults so a plain cmake invocation gives a useful error rather
# than silently building for the host platform.
if(NOT DEFINED CMAKE_SYSTEM_NAME)
    message(FATAL_ERROR
        "CMAKE_SYSTEM_NAME is not set.\n"
        "Pass -DCMAKE_SYSTEM_NAME=iOS to build for device, or see the comments "
        "at the top of this file for the full invocation.")
endif()

set(CMAKE_OSX_SYSROOT            "iphoneos"     CACHE STRING "iOS SDK sysroot")
set(CMAKE_OSX_DEPLOYMENT_TARGET  "16.0"         CACHE STRING "Minimum iOS deployment target")
set(CMAKE_OSX_ARCHITECTURES      "arm64"        CACHE STRING "Target architecture(s)")

# Disable components that don't apply to iOS.
# Set with FORCE so the options declared inside 3rdparty/CMakeLists.txt are overridden.
set(BUILD_HKP_SAUCER OFF CACHE BOOL "Disable Saucer GUI for iOS" FORCE)
set(ENABLE_FFMPEG    OFF CACHE BOOL "Disable FFmpeg for iOS"      FORCE)
set(BUILD_TESTING    OFF CACHE BOOL ""                             FORCE)

# ── Project ───────────────────────────────────────────────────────────────────
project(MeanderIOS VERSION 1.0 LANGUAGES CXX OBJCXX Swift)

# ── Dependencies ──────────────────────────────────────────────────────────────
# Pull in 3rdparty (vcpkg + Boost + OpenSSL etc.) and hkp-rt-lib.
# We include hkp-rt/lib directly to avoid building the server executable.
if(NOT TARGET hkp-rt-deps)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../3rdparty
        ${CMAKE_CURRENT_BINARY_DIR}/3rdparty
    )
endif()

if(NOT TARGET hkp-rt-lib)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../hkp-rt/lib
        ${CMAKE_CURRENT_BINARY_DIR}/hkp-rt-lib
    )
endif()

# ── Source files ──────────────────────────────────────────────────────────────
set(SWIFT_SOURCES
    MeanderIOS/App/MeanderIOSApp.swift
    MeanderIOS/Features/Boards/BoardListView.swift
    MeanderIOS/Features/Boards/BoardListViewModel.swift
    MeanderIOS/Models/BoardDraft.swift
    MeanderIOS/Models/Remote.swift
    MeanderIOS/Networking/MeanderAPIClient.swift
)

set(OBJCXX_SOURCES
    MeanderIOS/Runtime/HKPRuntimeHost.h
    MeanderIOS/Runtime/HKPRuntimeHost.mm
)

# ── Bundle resources ──────────────────────────────────────────────────────────
# CONFIGURE_DEPENDS re-runs cmake when new files appear under WebApp/.
file(GLOB_RECURSE WEBAPP_RESOURCES
    CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/MeanderIOS/Resources/WebApp/*"
)

# ── App target ────────────────────────────────────────────────────────────────
add_executable(MeanderIOS MACOSX_BUNDLE
    ${SWIFT_SOURCES}
    ${OBJCXX_SOURCES}
    ${WEBAPP_RESOURCES}
)

# ── Resource placement inside the bundle ─────────────────────────────────────
# Each WebApp file is placed under Resources/WebApp/<subpath> in the bundle,
# preserving the directory structure from MeanderIOS/Resources/.
foreach(RESOURCE_FILE ${WEBAPP_RESOURCES})
    file(RELATIVE_PATH REL_PATH
        "${CMAKE_CURRENT_SOURCE_DIR}/MeanderIOS/Resources"
        "${RESOURCE_FILE}"
    )
    get_filename_component(RESOURCE_SUBDIR "${REL_PATH}" DIRECTORY)
    set_source_files_properties("${RESOURCE_FILE}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/${RESOURCE_SUBDIR}"
    )
endforeach()

# ── Xcode / bundle properties ─────────────────────────────────────────────────
set_target_properties(MeanderIOS PROPERTIES
    # ── Bundle identity ───────────────────────────────────────────────────────
    MACOSX_BUNDLE_GUI_IDENTIFIER        "to.hookup.meander-ios"
    MACOSX_BUNDLE_BUNDLE_VERSION        "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING  "1.0"

    # Use the hand-authored Info.plist; CMake will expand $(VAR) references.
    MACOSX_BUNDLE_INFO_PLIST
        "${CMAKE_CURRENT_SOURCE_DIR}/MeanderIOS/Resources/Info.plist"

    # ── Swift ─────────────────────────────────────────────────────────────────
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.9"

    # Bridging header: path relative to $(SRCROOT) as Xcode expects.
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
        "$(SRCROOT)/MeanderIOS/App/MeanderIOS-Bridging-Header.h"

    # ── C++ (for ObjC++ files that include hkp-rt headers) ───────────────────
    CXX_STANDARD            20
    CXX_STANDARD_REQUIRED   ON
    XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
    XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY           "libc++"

    # ── iOS deployment ────────────────────────────────────────────────────────
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "16.0"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY     "1,2"   # 1 = iPhone, 2 = iPad

    # ── Architecture ─────────────────────────────────────────────────────────
    XCODE_ATTRIBUTE_ARCHS            "arm64"
    XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH "YES"

    # ── Code signing (set DEVELOPMENT_TEAM for device / App Store builds) ────
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE         "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM        ""   # e.g. "ABCDE12345"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY      "iPhone Developer"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "to.hookup.meander-ios"

    # ── Miscellaneous ─────────────────────────────────────────────────────────
    # Bitcode was deprecated in Xcode 14 and removed in Xcode 15.
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
)

# ── Linking ───────────────────────────────────────────────────────────────────
# hkp-rt-lib propagates its public include directories automatically.
target_link_libraries(MeanderIOS PRIVATE hkp-rt-lib)

# iOS system frameworks used by the Swift/ObjC++ app layer.
# (AudioToolbox, CoreFoundation, CoreAudio are already linked through hkp-rt-deps
# when building for Apple; listing them here is harmless and makes intent clear.)
target_link_libraries(MeanderIOS PRIVATE
    "-framework Foundation"
    "-framework UIKit"
    "-framework WebKit"
    "-framework AudioToolbox"
    "-framework CoreFoundation"
)

# ── Header search paths ───────────────────────────────────────────────────────
# The ObjC++ runtime host and the bridging header need to find each other.
target_include_directories(MeanderIOS PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/MeanderIOS
    ${CMAKE_CURRENT_SOURCE_DIR}/MeanderIOS/Runtime
)
