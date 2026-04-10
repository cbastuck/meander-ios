# To generate the Xcode project

# Device build

cmake -G Xcode -S meander-ios -B build/meander-ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_TOOLCHAIN_FILE=$(pwd)/3rdparty/vcpkg/scripts/buildsystems/vcpkg.cmake -DVCPKG_TARGET_TRIPLET=arm64-ios

open build/meander-ios/MeanderIOS.xcodeproj

For Simulator (Apple Silicon Mac): swap iphoneos → iphonesimulator and arm64-ios → arm64-ios-simulator.

One remaining step

Set your Apple Developer Team ID in the generated project (or in the CMakeLists before generating):  
 XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "ABCDE12345"  
 vcpkg must also have the arm64-ios packages installed — run vcpkg install with --triplet arm64-ios if Boost/OpenSSL haven't
been built for iOS yet.

# Simulator build

cmake --preset ios-simulator -S meander-ios  
open build/meander-ios-simulator/MeanderIOS.xcodeproj

vcpkg will build the arm64-ios-simulator packages into a separate vcpkg_installed/arm64-ios-simulator/ tree — fully  
 isolated from the device build. The two presets map to separate build/meander-ios-device/ and build/meander-ios-simulator/
directories, so you can have both Xcode projects open at once without conflicts.

## What this includes

- SwiftUI host shell with `WKWebView`
- Bundled Meander frontend loaded from app resources
- Custom `hkp://` scheme handler for:
  - `hkp://app/...` bundled frontend assets
  - `hkp://boards` local board list/load/save/delete
  - `hkp://remotes/` built-in remote runtime
  - `hkp://remotes/meander-ios/*` passthrough to the real `hkp-rt` HTTP server

## Runtime Bridge Configuration

Set these keys in `MeanderIOS/Resources/Info.plist`:

- `HKPRuntimeBaseURL` (default `http://127.0.0.1:5556`)
- `HKPRuntimeRemoteName` (default `meander-ios`)
- `HKPRuntimeAutoStart` (default `false`)
- `HKPRuntimePort` (default `5556`)
- `HKPRuntimeAllowedOrigins` (default `*`)

The web app always sees a remote URL under the custom scheme (`hkp://remotes/<name>`), and the iOS host translates that into HTTP calls to the configured runtime server.

## Embedded Runtime Mode

The iOS host now includes an Objective-C++ runtime host wrapper (`HKPRuntimeHost`) and app lifecycle hooks to start/stop an embedded `hkp-rt` server.

- Runtime autostart is controlled by `HKPRuntimeAutoStart`.
- When embedded runtime starts successfully, its URL is preferred over `HKPRuntimeBaseURL`.
- The Xcode target defaults to `HKP_EMBEDDED_RUNTIME=0`, so builds remain safe without native `hkp-rt` iOS libs.

To enable true in-process runtime:

1. Build/link iOS-compatible `hkp-rt` + dependencies (not macOS archives).
2. Set `HKP_EMBEDDED_RUNTIME=1` in target preprocessor definitions.
3. Ensure header/library search paths include `hkp-rt/lib/include` and the iOS-built runtime archive/deps.
