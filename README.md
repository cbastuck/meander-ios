# meander-ios

SwiftUI iOS app that embeds the Meander mobile playground in a `WKWebView` backed by an in-process `hkp-rt` runtime.

## Building

Use `build-ios.sh` from the **repo root**. It builds the mobile web app first, then configures and compiles the native target.

```bash
# Physical device (arm64)
./build-ios.sh device Release

# Simulator (Apple Silicon)
./build-ios.sh simulator Debug
```

The script:
1. Runs `npm run build:ios` in `meander/frontend/` — outputs the mobile web app directly into `MeanderIOS/Resources/WebApp/`
2. Runs `cmake --preset ios-device` (or `ios-simulator`) — generates `build/meander-ios-device/MeanderIOS.xcodeproj`
3. Builds the native target via `cmake --build`

To iterate on the native side without rebuilding the frontend, open the generated project directly:

```bash
open build/meander-ios-device/MeanderIOS.xcodeproj
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

## Configuration (`MeanderIOS/Resources/Info.plist`)

| Key | Default | Purpose |
|-----|---------|---------|
| `HKPRuntimeAutoStart` | `true` | Start `hkp-rt` on launch |
| `HKPRuntimePort` | `5556` | Port the embedded runtime listens on |
| `HKPRuntimeBaseURL` | `http://127.0.0.1:5556` | Fallback URL if embedded runtime doesn't start |
| `HKPRuntimeRemoteName` | `meander-ios` | Name shown for the built-in remote |
| `HKPRuntimeAllowedOrigins` | `*` | CORS origins allowed by the runtime |
| `DEV_WEBAPP_URL` | `http://127.0.0.1:8555` *(remove for production)* | Load web app from a dev server instead of the bundle. Use `http://127.0.0.1:8555` in the **Simulator** (it reaches the host Mac's vite server and is a secure context, so the cloud view's Auth0/PKCE login works). A LAN IP like `http://192.168.x.x:8555` works for a physical device but is **not** a secure context — `crypto.subtle` is unavailable there, so cloud login breaks, and hkp-frontend's `AuthProvider` strips the `Auth0Provider` on `http://192.168.*`. For device cloud-login testing, serve over HTTPS (tunnel or mkcert) instead. |

## App identity

| Field | Value |
|-------|-------|
| Bundle ID | `com.readymadeit.app-ios` |
| Display name | `Meander` |
| Deployment target | iOS 16.0 |
| Architecture | arm64 |
