# Tank Arena

A Diep.io-style top-down tank shooter for mobile, packaged for Android with
[Apache Cordova](https://cordova.apache.org/) and updated over-the-air (OTA) so
the APK only has to be compiled once.

## Architecture (OTA patch-loader)

The APK ships a tiny **bootstrapper** and a **bundled fallback** of the game;
the real game is hosted on GitHub Pages and updated without recompiling:

| File | Role |
| --- | --- |
| `www/index.html` | OTA bootstrapper compiled into the APK. Shows a loading overlay, checks the remote version, downloads/caches the game, then boots it. Contains no game logic. |
| `docs/game.html` | **Canonical game** (all logic: 6000² map, dense shapes, 25-class evolution tree, joysticks, Status menu). Served from GitHub Pages. |
| `docs/version.json` | `{"version": "1.0.2", ...}` — bump `version` to ship an update. |
| `www/game.html` | Bundled fallback copy, generated from `docs/game.html` by `npm run sync:game` (git-ignored). Guarantees the APK runs on a fresh offline first-run. |

**Boot flow:** on launch the bootstrapper fetches `docs/version.json` from Pages,
compares it to the version cached locally (Cache Storage API, falling back to
`localStorage`). If the remote version is newer it downloads `game.html` with a
progress bar ("Downloading new update data… Please wait."), caches it with a
cache-busting query, and boots it in a full-screen iframe. If the app is up to
date, offline, or the download fails, it instantly boots the last cached copy —
or the bundled fallback on a fresh offline first-run — so the game is always
playable.

### Shipping an update (no recompile)

1. Edit `docs/game.html`.
2. Bump `"version"` in `docs/version.json` (e.g. `1.0.2` → `1.0.3`).
3. Push. The `deploy-pages` workflow publishes `docs/` to GitHub Pages.
4. Existing installs pick up the update on their next launch.

The bootstrapper's `OTA_BASE` defaults to `https://kkbanini.github.io/gaga2/`
(override with `window.OTA_BASE_URL`). **One-time setup:** enable GitHub Pages
(Settings → Pages → Source: *GitHub Actions*) so the OTA endpoint goes live.
Until then the APK still runs fine from its bundled fallback.

## Gameplay features

- Dual virtual joysticks (move + aim/auto-fire), WASD/mouse fallback on desktop.
- A large 6000×6000 world densely populated with shapes (triangles/squares/
  pentagons) to farm for XP.
- An **8-stat** skill-point menu opened via the **Status** button under the
  health bar: Health Regen, Max Health, Body Damage, Bullet Speed, Bullet
  Penetration, Bullet Damage, Reload, Movement Speed (cap 8, raised to 10 for
  the Smasher line).
- **Rammer / body-damage mechanics** — colliding with a shape damages both it
  and you; Body Damage tunes the ramming output.
- An **authentic Diep.io class evolution tree** — pick a base class at Level 15
  (Twin, Sniper, Machine Gun, Flank Guard, or the Rammer/Basic path), then a
  Tier-3 sub-class at Level 30 and a Tier-4 at Level 45. Distinct weapon
  mechanics per branch: cone Machine Gun, 11-barrel Spread Shot, 8-way Octo
  Tank, Hunter's large+small twin bullets, sniper viewport zoom, Stalker
  invisibility, Destroyer/Annihilator recoil, Tri-Angle/Booster recoil thrust,
  Auto Gunner / Hybrid / Auto-Smasher auto-turrets, and the gunless Smasher →
  Auto-Smasher / Spike ramming line.
- Health regeneration after a few seconds without taking damage.
- Smooth camera follow.
- A **main-menu lobby** (Diep.io style): FFA or 2 Teams and username entry. In
  2 Teams mode the tank/bullet/nameplate take the team colour, the server
  auto-balances the two teams on join, and same-team friendly fire is disabled.
- **True real-time online multiplayer** (see below): other tanks on the map are
  *real players*, and a **top-right minimap** (safe-area aware) shows you, the
  other players (team-coloured), and a pulsing skull at the boss.
- A **Mythical Boss** spawns at the map center every 10 minutes (with a 10-second
  blinking warning). One of four bosses appears — Polygon King, Summoner Core,
  Giga Smasher, Omega Dreadnought — each with a giant health bar. Landing the
  kill instantly grants the player **+10 levels** (capped at level 45) and posts
  a global "[name] has defeated the [boss]!" notification.

## Try it instantly (no build required)

The game is plain HTML/CSS/JS with no dependencies. To play the game directly
(bypassing the OTA bootstrapper), serve the `docs/` folder and open
`game.html`:

```
python3 -m http.server 8000 -d docs
```

Then visit `http://localhost:8000/game.html`. Use WASD + mouse to play on
desktop, or open Chrome DevTools' device toolbar (touch emulation) to try the
dual virtual joysticks. To exercise the full OTA boot flow instead, serve `www/`
(run `npm run sync:game` first) and open its `index.html`.

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

## Online multiplayer (real-time)

The game has **true real-time online multiplayer** over WebSockets. When a
server URL is configured, every client connects automatically on **Play!** and
syncs — in real time, across everyone connected — each tank's position, barrels
(class/turret), bullet fire events, level, score, team (Red/Blue) and name.
Your friends install the APK, type a name, and you see their tanks moving and
shooting on your screen.

**Architecture (relay, peer-authoritative over self):** each client simulates
and owns its *own* tank and HP and broadcasts that state ~20 Hz; the server
relays everyone's state + fire events and balances the two teams on join. Remote
tanks are interpolated between snapshots; a peer's `fire` event spawns a locally
simulated bullet that can damage your tank. The local simulation always stays
authoritative for your own tank, so an unreachable server **never** breaks
single-player — the game just runs solo and auto-reconnects in the background.

### Run a server

A complete, production-ready Node.js server lives in [`server/`](server/) — one
`server.js` (using [`ws`](https://www.npmjs.com/package/ws)) plus a
`package.json`. It manages the global arena, relays movement/fire, and handles
2-Teams balancing. See [`server/README.md`](server/README.md) for **free
hosting instructions on Render, Railway, or Fly.io**.

```bash
cd server && npm install && npm start   # ws://localhost:8080
```

### Point the game at your server

The client reads the endpoint from (in order):

1. `window.TANK_NET_URL` — set before the game loads (handy for local testing):
   ```html
   <script>window.TANK_NET_URL = "wss://your-app.onrender.com";</script>
   ```
2. The `MULTIPLAYER_URL` constant near the top of `docs/game.html` — replace the
   placeholder with your deployed URL and everyone (including the APK, after the
   OTA update ships) connects automatically.

**Use `wss://` (TLS) in production.** A page served over HTTPS (GitHub Pages or
the APK's cached copy) is blocked from opening an insecure `ws://` socket;
`ws://` is only for `http://localhost` testing.

From the browser console you can inspect the live connection with
`TankMP.connected`, `TankMP.id`, and `TankMP.remotes`.

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
