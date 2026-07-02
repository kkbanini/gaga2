# Tank Arena

A Diep.io-style top-down tank shooter for mobile, built as a single-file HTML5
Canvas game (`www/index.html`) and packaged for Android with [Apache
Cordova](https://cordova.apache.org/).

## Gameplay features

- Dual virtual joysticks (move + aim/auto-fire), WASD/mouse fallback on desktop.
- A large 6000×6000 world densely populated with shapes (triangles/squares/
  pentagons) to farm for XP.
- A 6-stat skill-point upgrade menu (Speed, Reload, Damage, Health, Body Dmg,
  Shield) opened via the **Status** button under the health bar.
- **Rammer / body-damage mechanics** — colliding with a shape damages both it
  and you; Body Dmg and Shield tune the exchange.
- A **deep class evolution tree** — pick a base class at Level 15 (Twin, Sniper,
  Machine Gun, Flank Guard, Smasher), then a Tier-3 sub-class at Level 30 and a
  Tier-4 at Level 45 (25 classes total, e.g. Smasher → Auto-Smasher/Spike →
  Auto-Spike/Mega-Spike).
- Health regeneration after a few seconds without taking damage.
- Smooth camera follow.

## Try it instantly (no build required)

The game is plain HTML/CSS/JS with no dependencies, so you can just open it
in a browser:

```
python3 -m http.server 8000 -d www
```

Then visit `http://localhost:8000`. Use WASD + mouse to play on desktop, or
open Chrome DevTools' device toolbar (touch emulation) to try the dual
virtual joysticks.

## Building a real Android .apk

### Prerequisites

- Node.js 18+
- JDK 17
- Android SDK, with `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) set and pointing
  at an installation that has `platform-tools`, `platforms;android-34`, and
  `build-tools` installed. The easiest way to get this is installing
  [Android Studio](https://developer.android.com/studio) once and letting it
  manage the SDK, or installing the [command-line
  tools](https://developer.android.com/tools/sdkmanager) directly.
- Accept the Android SDK licenses: `sdkmanager --licenses`

### Build

```
npm install
npx cordova platform add android
npx cordova build android
```

The debug APK is written to:

```
platforms/android/app/build/outputs/apk/debug/app-debug.apk
```

Install it on a connected device/emulator with `adb install <path-to-apk>`,
or run `npx cordova run android` to build, install, and launch in one step.

For a release build (`npx cordova build android --release`), you'll need to
configure signing — see the [Cordova Android platform
guide](https://cordova.apache.org/docs/en/latest/guide/platforms/android/)
for keystore setup.

### Building without installing Android Studio locally

Push to this branch (or trigger it manually) to run
`.github/workflows/build-android.yml`, which installs the Android SDK,
builds a debug APK in CI, and uploads it as a downloadable workflow
artifact — no local Android tooling required.

## Online multiplayer (foundation)

The game ships with a lightweight, transport-only WebSocket client scaffold
(`NET` in `www/index.html`). It is **disabled by default** so the game runs
fully offline in the APK. To connect to a server, set the endpoint before the
game loads:

```html
<script>window.TANK_NET_URL = "wss://your-server.example";</script>
```

or call `NET.connect("wss://…")` at runtime. The JSON wire protocol is
documented inline above the `NET` object. When connected, the client pushes the
local tank's state (~20 Hz) and renders remote players/bullets from server
`snapshot` frames. The local simulation stays authoritative for the local tank,
so a missing/unreachable server never breaks single-player. Note: no game
*server* is included — this is the client foundation to build one against.

## iOS / Safari / WebView support

The frontend is hardened for Apple Safari and iOS WebViews:

- `viewport-fit=cover` + `user-scalable=no` and `position: fixed` on the body to
  stop pinch-zoom and rubber-band/bounce scrolling.
- `gesturestart`/`dblclick` are suppressed to kill double-tap and pinch zoom.
- Safe-area insets (`env(safe-area-inset-*)`) are read at runtime and applied to
  the HUD/Status button so nothing hides under a notch or home indicator.

## Notes

- This is a single self-contained `www/index.html` (no bundler/patch-loader);
  the Cordova build simply copies it into the Android assets.
- `config.xml` uses a placeholder app id (`com.gaga2.tankarena`) and author
  email — change these before any real release.
- No custom app icon/splash screen is configured yet, so Cordova's default
  template assets are used. To add your own, see the [Cordova icons &
  splash screens guide](https://cordova.apache.org/docs/en/latest/config_ref/images.html)
  and reference the files under a `<platform name="android">` block in
  `config.xml`.
- The game deliberately doesn't lock orientation natively — `www/index.html`
  already adapts its layout responsively to both portrait and landscape.
