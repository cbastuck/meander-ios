# meander-ios

SwiftUI iOS app that embeds the Readymade mobile playground in a `WKWebView` backed by an in-process `hkp-rt` runtime.

## Building

Use `build-ios.sh` from the **repo root**. It builds the mobile web app first, then configures and compiles the native target.

```bash
# Physical device (arm64)
./build-ios.sh device Release

# Simulator (Apple Silicon)
./build-ios.sh simulator Debug
```

The script:
1. Runs `npm run build:ios` in `meander/frontend/` — outputs the mobile web app directly into `ReadymadeIOS/Resources/WebApp/`
2. Runs `cmake --preset ios-device` (or `ios-simulator`) — generates `build/meander-ios-device/ReadymadeIOS.xcodeproj`
3. Builds the native target via `cmake --build`

To iterate on the native side without rebuilding the frontend, open the generated project directly:

```bash
open build/meander-ios-device/ReadymadeIOS.xcodeproj
```

### Prerequisites

- vcpkg `arm64-ios` packages (Boost, OpenSSL) — built automatically on first run
- A Developer Team ID for device builds — set `XCODE_ATTRIBUTE_DEVELOPMENT_TEAM` in `CMakeLists.txt` or override in Xcode

## Architecture

### SwiftUI shell

`BoardListView` hosts a `WKWebView` that loads `hkp://app/index.html` from bundled resources. A `WKURLSchemeHandler` intercepts all `hkp://` traffic and routes it natively.

### Platform marker

Before any page JS runs, a `WKUserScript` injects:

```js
window.__MEANDER_IOS__ = true;
```

The web app reads this in `main.tsx` to select the mobile playground (`MobileApp`) instead of the desktop one — no user-agent sniffing.

### `hkp://` scheme routes

| Host | Purpose |
|------|---------|
| `hkp://app/…` | Bundled frontend assets (`WebApp/`) |
| `hkp://boards/…` | Local board list / load / save / delete (stored in `Documents/Boards/`) |
| `hkp://remotes/` | Lists the built-in embedded runtime as a remote |
| `hkp://remotes/meander-ios/…` | Proxies REST calls to the `hkp-rt` HTTP server |

### Mobile web app

Built from `meander/frontend/` via `vite.config.ios.ts`. Renders `MobilePlaygroundWithRouter` with:

- `"mobile"` theme
- Safe-area insets on the top bar and bottom tab bar (`env(safe-area-inset-*)`) for Dynamic Island / notch / home indicator
- `availableRuntimeEngines` populated from `hkp://remotes/` (the embedded runtime appears automatically)

## Configuration (`ReadymadeIOS/Resources/Info.plist`)

| Key | Default | Purpose |
|-----|---------|---------|
| `HKPRuntimeAutoStart` | `true` | Start `hkp-rt` on launch |
| `HKPRuntimePort` | `5556` | Port the embedded runtime listens on |
| `HKPRuntimeBaseURL` | `http://127.0.0.1:5556` | Fallback URL if embedded runtime doesn't start |
| `HKPRuntimeRemoteName` | `meander-ios` | Name shown for the built-in remote |
| `HKPRuntimeAllowedOrigins` | `*` | Origins the runtime allows. `*` applies to requests that carry a token; a page calling without one is let in only if it is the app's own (`hkp://app`), is served from the device itself, or — in a Debug build — is the origin of `DEV_WEBAPP_URL` |
| `DEV_WEBAPP_URL` | `$(DEV_WEBAPP_URL)` — a build setting: `http://127.0.0.1:8555` for the simulator, empty for a device | Debug builds only: load the web app from a dev server instead of the bundle. Empty loads the bundle. The simulator's default reaches the host Mac's Vite server and is a secure context, so the cloud view's Auth0/PKCE login works. A device needs the Mac's LAN address set in Xcode's Build Settings, which `build-ios.sh` resets — see "Loading the web app from a dev server" in the repo's `README-ios.md`. Such an address is **not** a secure context: `crypto.subtle` is unavailable there, so cloud login breaks, and hkp-frontend's `AuthProvider` strips the `Auth0Provider` on `http://192.168.*`. For device cloud-login testing, serve over HTTPS (tunnel or mkcert) instead. |

## App identity

| Field | Value |
|-------|-------|
| Bundle ID | `com.readymadeit.app-ios` |
| Display name | `Readymade` |
| Deployment target | iOS 16.0 |
| Architecture | arm64 |
