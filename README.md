# Tank Arena

A Diep.io-style top-down tank shooter for mobile, built as a single-file HTML5
Canvas game (`www/index.html`) and packaged for Android with [Apache
Cordova](https://cordova.apache.org/).

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

## Notes

- `config.xml` uses a placeholder app id (`com.gaga2.tankarena`) and author
  email — change these before any real release.
- No custom app icon/splash screen is configured yet, so Cordova's default
  template assets are used. To add your own, see the [Cordova icons &
  splash screens guide](https://cordova.apache.org/docs/en/latest/config_ref/images.html)
  and reference the files under a `<platform name="android">` block in
  `config.xml`.
- The game deliberately doesn't lock orientation natively — `www/index.html`
  already adapts its layout responsively to both portrait and landscape.
