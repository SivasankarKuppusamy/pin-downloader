# PinVideo — Flutter, no remote backend

This personal-use starter supports Android share intents, clipboard paste, best-effort inspection of a public Pin page in a WebView, direct video downloads, and saving to the Gallery with `gal`.

## Important limitation

This version does **not** contain a Pinterest extraction engine. It tries to inspect the public Pin page for a direct video URL exposed in the DOM or metadata. Pinterest often loads media dynamically or protects it, so many Pin links will not yield a direct URL. The app intentionally does not sign in or bypass restrictions. A Pin webpage URL is not itself a video file.

The quality selector is currently UI-only because this no-backend approach downloads the direct file found on the page; it cannot transcode or choose among Pinterest's internal renditions. A future on-device extractor would be needed for broader support.

## Setup

Install Flutter SDK and Android Studio. From this project folder:

```bash
flutter create .
flutter pub get
flutter run
```

To build an APK:

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.

## Share-to-app test

1. Install/run the app on an Android device.
2. In Pinterest, open a public Pin and tap Share.
3. Choose PinVideo. If it is not shown, use “Copy link” in Pinterest and paste it into PinVideo.
4. Tap “Find video on Pin page”.
5. If a direct media URL is found, tap “Download to Gallery”.

## Android notes

- `INTERNET` permission is declared in `AndroidManifest.xml`.
- The `ACTION_SEND` / `text/plain` intent filter lets Android list the app as a share target. `receive_sharing_intent` reads shared content for warm and cold starts.
- `gal` writes the downloaded video to the Gallery and handles relevant media permissions. Android 10+ generally uses scoped storage; don't request broad storage access for this workflow.
- Use HTTPS media URLs. If you later use a local HTTP server, Android cleartext configuration may be required, but this project does not need one.
- Test intent handling on a real Android device. Some share targets send a URL as text; others send a browser URL or title plus URL.

## Caveats

- DOM extraction is best effort and may fail due to dynamic rendering, redirects, cookies, expiring URLs, or site changes.
- The direct-download path only accepts URLs whose path ends in a known video extension. Some legitimate media URLs do not have extensions and will be rejected.
- No server is used, but WebView still loads Pinterest's website over the internet.
- Respect copyright, creators' permissions, Pinterest terms, and local law. Do not use this app to access private Pins or bypass access controls.
- Before publishing, review dependencies, privacy behavior, error handling, and current Android target SDK requirements.


## Build an APK with GitHub Actions (no Flutter install on your PC)

This ZIP includes `.github/workflows/build-apk.yml`. To use it:

1. Create a repository at https://github.com/new (a private repository is fine).
2. Upload all project files, including the hidden `.github/workflows/build-apk.yml` file, and commit them to `main`. Using GitHub Desktop or Git is the most reliable way to include the hidden `.github` folder.
3. Open the repository's **Actions** tab and select **Build PinVideo APK**. If it hasn't run automatically, select **Run workflow**.
4. When the workflow finishes successfully, open the run and download the **pinvideo-android-apk** artifact. Extract the downloaded artifact ZIP; it contains `app-release.apk`.
5. Copy the APK to your Android phone, open it, and allow installation from that file source if Android asks.

The build workflow compiles the Android package; it does not make Pinterest extraction more reliable. This app only tries to discover publicly exposed direct video URLs locally, so many Pins will still not be downloadable without a real on-device extractor. The quality options are currently display-only.
