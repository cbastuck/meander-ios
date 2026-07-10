cmake_minimum_required(VERSION 3.21)

# ── iOS platform settings ─────────────────────────────────────────────────────
# These MUST be cache variables set before project() so the Xcode generator
# picks up the right SDK and deployment target.
#
# Use the CMakePresets.json presets (recommended):
#
#   # Physical device (arm64-ios)
#   cmake --preset ios-device   (from repo root or meander-ios/)
#   open build/meander-ios-device/ReadymadeIOS.xcodeproj
#
#   # Simulator on Apple Silicon (arm64-ios-simulator)
#   cmake --preset ios-simulator
#   open build/meander-ios-simulator/ReadymadeIOS.xcodeproj
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
project(ReadymadeIOS VERSION 1.0 LANGUAGES CXX OBJCXX Swift)

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
    ReadymadeIOS/App/ReadymadeIOSApp.swift
    ReadymadeIOS/Features/Auth/AuthSessionBridge.swift
    ReadymadeIOS/Features/Boards/BoardListView.swift
    ReadymadeIOS/Features/Boards/BoardListViewModel.swift
    ReadymadeIOS/Features/Boards/JSConsoleBridge.swift
    ReadymadeIOS/Features/Boards/ShareRouter.swift
    ReadymadeIOS/Models/BoardDraft.swift
    ReadymadeIOS/Models/Remote.swift
    ReadymadeIOS/Networking/MeanderAPIClient.swift
    ReadymadeIOS/Shared/ShareInbox.swift
)

set(OBJCXX_SOURCES
    ReadymadeIOS/Runtime/HKPRuntimeHost.h
    ReadymadeIOS/Runtime/HKPRuntimeHost.mm
    ReadymadeIOS/Runtime/Services/DeviceMotionService.h
    ReadymadeIOS/Runtime/Services/DeviceMotionService.mm
    ReadymadeIOS/Runtime/Services/LocationService.h
    ReadymadeIOS/Runtime/Services/LocationService.mm
    ReadymadeIOS/Runtime/Services/MicrophoneService.h
    ReadymadeIOS/Runtime/Services/MicrophoneService.mm
    ReadymadeIOS/Runtime/Services/SpeakerService.h
    ReadymadeIOS/Runtime/Services/SpeakerService.mm
)

# ── Bundle resources ──────────────────────────────────────────────────────────
# CONFIGURE_DEPENDS re-runs cmake when new files appear under WebApp/.
file(GLOB_RECURSE WEBAPP_RESOURCES
    CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/Resources/WebApp/*"
)

# ── App target ────────────────────────────────────────────────────────────────
add_executable(ReadymadeIOS MACOSX_BUNDLE
    ${SWIFT_SOURCES}
    ${OBJCXX_SOURCES}
    ${WEBAPP_RESOURCES}
    ReadymadeIOS/Assets.xcassets
    ReadymadeIOS/Resources/PrivacyInfo.xcprivacy
)

# ── Resource placement inside the bundle ─────────────────────────────────────
# Asset catalog: MACOSX_PACKAGE_LOCATION forces CMake to emit a PBXBuildFile
# entry so Xcode places it in the Copy Bundle Resources phase and runs actool.
set_source_files_properties(
    ReadymadeIOS/Assets.xcassets
    PROPERTIES MACOSX_PACKAGE_LOCATION "Resources"
)

# Privacy manifest: Apple requires PrivacyInfo.xcprivacy in the bundle for
# App Store submission. Placed in Copy Bundle Resources like the asset catalog.
set_source_files_properties(
    ReadymadeIOS/Resources/PrivacyInfo.xcprivacy
    PROPERTIES MACOSX_PACKAGE_LOCATION "Resources"
)

# Each WebApp file is placed under Resources/WebApp/<subpath> in the bundle,
# preserving the directory structure from ReadymadeIOS/Resources/.
foreach(RESOURCE_FILE ${WEBAPP_RESOURCES})
    file(RELATIVE_PATH REL_PATH
        "${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/Resources"
        "${RESOURCE_FILE}"
    )
    get_filename_component(RESOURCE_SUBDIR "${REL_PATH}" DIRECTORY)
    set_source_files_properties("${RESOURCE_FILE}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/${RESOURCE_SUBDIR}"
    )
endforeach()

# ── Xcode / bundle properties ─────────────────────────────────────────────────
set_target_properties(ReadymadeIOS PROPERTIES
    # Emit a shared .xcscheme for the app so it is always present and selectable
    # in Xcode. Without this the project ships no scheme files and Xcode
    # autocreates them per-user; once the Share Extension target was added, that
    # autocreation surfaced the extension's scheme instead of the app's (the app
    # target appeared "missing" from the scheme picker). The extension is an
    # app-extension and can't be run standalone anyway — the app is the only
    # runnable scheme.
    XCODE_GENERATE_SCHEME ON

    # ── Bundle identity ───────────────────────────────────────────────────────
    MACOSX_BUNDLE_GUI_IDENTIFIER        "com.readymadeit.app-ios"
    MACOSX_BUNDLE_BUNDLE_VERSION        "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING  "1.0"

    # Info.plist references $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION);
    # CMake-generated projects don't define these, so without them the bundle
    # ships with empty CFBundleShortVersionString/CFBundleVersion (App Store
    # Connect rejects that). MARKETING_VERSION = user-facing (e.g. "1.0"),
    # CURRENT_PROJECT_VERSION = build number, must increase per upload.
    XCODE_ATTRIBUTE_MARKETING_VERSION       "1.0"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "1"

    # Use the hand-authored Info.plist; CMake will expand $(VAR) references.
    MACOSX_BUNDLE_INFO_PLIST
        "${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/Resources/Info.plist"

    # ── Swift ─────────────────────────────────────────────────────────────────
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.9"

    # CMake-generated projects don't set these automatically; without them
    # #if DEBUG is never true in debug builds, and assert() is never stripped
    # in release builds (ObjC++/C++ side via GCC_PREPROCESSOR_DEFINITIONS).
    "XCODE_ATTRIBUTE_SWIFT_ACTIVE_COMPILATION_CONDITIONS[variant=Debug]"   "DEBUG"
    "XCODE_ATTRIBUTE_SWIFT_ACTIVE_COMPILATION_CONDITIONS[variant=Release]" "NDEBUG"

    "XCODE_ATTRIBUTE_GCC_PREPROCESSOR_DEFINITIONS[variant=Debug]"   "DEBUG=1 $(inherited)"
    "XCODE_ATTRIBUTE_GCC_PREPROCESSOR_DEFINITIONS[variant=Release]" "NDEBUG=1 $(inherited)"

    # Bridging header: path relative to $(SRCROOT) as Xcode expects.
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
        "$(SRCROOT)/ReadymadeIOS/App/ReadymadeIOS-Bridging-Header.h"

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
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.readymadeit.app-ios"

    # ── Entitlements (LAN discovery needs the multicast entitlement) ──────────
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS
        "${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/Resources/ReadymadeIOS.entitlements"

    # ── App icon ──────────────────────────────────────────────────────────────
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"

    # ── Dev web app redirect ──────────────────────────────────────────────────
    # Info.plist's DEV_WEBAPP_URL = $(DEV_WEBAPP_URL). Defined only for the
    # simulator SDK, so device / App Store builds expand it to empty (the app
    # then loads the bundled WebApp). The dev server at 127.0.0.1:8555 is only
    # reachable from the Simulator anyway. Keep this in sync with the dev
    # server port in meander/frontend's vite config.
    XCODE_ATTRIBUTE_DEV_WEBAPP_URL ""
    "XCODE_ATTRIBUTE_DEV_WEBAPP_URL[sdk=iphonesimulator*]" "http://127.0.0.1:8555"

    # ── Miscellaneous ─────────────────────────────────────────────────────────
    # Bitcode was deprecated in Xcode 14 and removed in Xcode 15.
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
)

# ── Linking ───────────────────────────────────────────────────────────────────
# hkp-rt-lib propagates its public include directories automatically.
target_link_libraries(ReadymadeIOS PRIVATE hkp-rt-lib)

# iOS system frameworks used by the Swift/ObjC++ app layer.
# (AudioToolbox, CoreFoundation, CoreAudio are already linked through hkp-rt-deps
# when building for Apple; listing them here is harmless and makes intent clear.)
target_link_libraries(ReadymadeIOS PRIVATE
    "-framework Foundation"
    "-framework UIKit"
    "-framework WebKit"
    "-framework AudioToolbox"
    "-framework AVFoundation"
    "-framework CoreFoundation"
    "-framework CoreMotion"
    "-framework CoreLocation"
)

# ── Header search paths ───────────────────────────────────────────────────────
# The ObjC++ runtime host and the bridging header need to find each other.
target_include_directories(ReadymadeIOS PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS
    ${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/Runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/Runtime/Services
)

# ── Share Extension target ────────────────────────────────────────────────────
# A separate .appex bundle embedded in the app. It runs in its own process when
# the user taps "Readymade" in the iOS share sheet: it captures the shared URL
# and/or text, drops a normalized envelope into the App Group inbox, and opens
# the host app via readymade://share?id=<id>. ShareInbox.swift is compiled into
# BOTH targets (the App Group container is their only shared channel).
add_executable(ReadymadeShareExtension MACOSX_BUNDLE
    ReadymadeIOS/ShareExtension/ShareViewController.swift
    ReadymadeIOS/Shared/ShareInbox.swift
)

set_target_properties(ReadymadeShareExtension PROPERTIES
    # Make CMake emit an app-extension (.appex) rather than a standalone app.
    BUNDLE_EXTENSION "appex"
    XCODE_PRODUCT_TYPE            "com.apple.product-type.app-extension"
    # An .appex executable is a real Mach-O executable (mh_execute), NOT a
    # loadable bundle. It has no main() of its own — the entry point is
    # NSExtensionMain (provided by Foundation), selected with the -e linker
    # flag. (Setting mh_bundle links without a main but produces a binary the
    # system cannot posix_spawn → "Exec format error", so the extension flashes
    # and bounces back to the share sheet.)
    XCODE_ATTRIBUTE_MACH_O_TYPE  "mh_execute"
    XCODE_ATTRIBUTE_OTHER_LDFLAGS "-e _NSExtensionMain"

    # Bundle identity: an extension's id must be prefixed by the host app's id.
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.readymadeit.app-ios.ShareExtension"
    XCODE_ATTRIBUTE_MARKETING_VERSION         "1.0"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION   "1"
    MACOSX_BUNDLE_INFO_PLIST
        "${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/ShareExtension/Info.plist"

    # Pin the Swift module name so NSExtensionPrincipalClass
    # (ReadymadeShareExtension.ShareViewController) resolves deterministically.
    # CMake doesn't set PRODUCT_MODULE_NAME, so relying on $(PRODUCT_MODULE_NAME)
    # in the Info.plist would expand to empty and the extension would fail to
    # load (flash, then bounce back to the share sheet).
    XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "ReadymadeShareExtension"
    XCODE_ATTRIBUTE_PRODUCT_NAME        "ReadymadeShareExtension"

    # Swift + deployment settings, mirrored from the app target.
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.9"
    "XCODE_ATTRIBUTE_SWIFT_ACTIVE_COMPILATION_CONDITIONS[variant=Debug]"   "DEBUG"
    "XCODE_ATTRIBUTE_SWIFT_ACTIVE_COMPILATION_CONDITIONS[variant=Release]" "NDEBUG"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "16.0"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY     "1,2"
    XCODE_ATTRIBUTE_ARCHS            "arm64"
    XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH "YES"
    XCODE_ATTRIBUTE_ENABLE_BITCODE   "NO"

    # Code signing: App Group entitlement so it shares the inbox with the app.
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE     "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM    ""
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY  "iPhone Developer"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS
        "${CMAKE_CURRENT_SOURCE_DIR}/ReadymadeIOS/ShareExtension/ShareExtension.entitlements"
)

target_link_libraries(ReadymadeShareExtension PRIVATE
    "-framework Foundation"
    "-framework UIKit"
    "-framework UniformTypeIdentifiers"
)

# Embed and code-sign the extension inside the app's PlugIns folder so it ships
# as part of ReadymadeIOS.app and registers with the share sheet on install.
set_target_properties(ReadymadeIOS PROPERTIES
    XCODE_EMBED_APP_EXTENSIONS                        "ReadymadeShareExtension"
    XCODE_EMBED_APP_EXTENSIONS_CODE_SIGN_ON_COPY      "YES"
)
add_dependencies(ReadymadeIOS ReadymadeShareExtension)
