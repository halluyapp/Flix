# FLIX

Flix is an original Flutter streaming-discovery app for Android. It combines a TMDB catalogue, a verified short-film **Clips** feed, and playback through the configured Zarhosting provider, with its own brand identity and product scope.

The GitHub Actions workflow installs the APK in an Android emulator, launches Flix, exercises Home and Clips, verifies both source badges in the Android UI hierarchy, and uploads genuine emulator screenshots as the `flix-readme-screenshot` artifact. Home shows `SUPABASE` only after a valid HTTP 200 JSON response from Flix's TMDB Edge Function during that load; Clips reports whether its items came from Supabase or the direct-provider fallback. These badges verify catalogue API reachability, not an authenticated user session or cloud-synced viewer state.

## What is implemented

- **Home** — trending, top-rated, regional, and genre rails from TMDB.
- **Clips** — a vertical discovery feed built from real Zarhosting catalogue records. An item is included only when the provider marks it as a movie, explicitly tags it with the `Short` genre, and reports `has_resource: true`. Query-only matches, series, and explicit adult genres, flags, or age ratings are excluded. Playback passes the provider's subject ID and slug directly to the existing player rather than guessing a TMDB match.
- **New & Hot** — remains available as a separate bottom-navigation destination.
- **Search and My Flix** — existing discovery and viewer-state screens remain in place.
- **Universal Android package** — CI builds one APK and checks that it contains ARMv7, ARM64, and x86_64 native libraries.

## Supabase backend

Flix's dedicated project is **Flix** (`jewtsdupzwwkdoudwgyk`, `eu-west-2`). The repository is linked to this project in `supabase/config.toml`.

- `supabase/migrations/20261114154911_flix_platform_hardening.sql` is the repository's intended schema for profiles, watch progress, My List, ratings, profile settings, release reminders, and a server-only stream cache, with row-level security and profile ownership checks. The remote project history contains version `20261114154911`; its applied SQL was not compared with this file during this verification.
- `supabase/functions/clips-feed` is deployed and returns provider-backed short-film records after applying the strict metadata filter. The app falls back to the same filter against the provider if Supabase is unavailable.
- `supabase/functions/tmdb-proxy` is deployed with a fixed endpoint allowlist and a per-isolate request limit. TMDB requests are proxied through Supabase so the bearer token is not compiled into the APK. The current `TMDB_READ_TOKEN` is a Supabase Edge Function secret.
- No Supabase API, service-role, or secret key is included in the app. The public Clips endpoint returns catalogue metadata only.

**Credential rotation:** this TMDB read token was present in the repository before this change, so rotate it with TMDB and update the Supabase `TMDB_READ_TOKEN` secret before a public/store release. Removing it from the current Flutter source does not erase prior Git history.

**Viewer-state limitation:** profiles, My List, and watch progress are still stored on-device by the current Flutter app. The app does not yet initialize Supabase Auth, create a signed-in session, or read/write those user records through Supabase; there is no cross-device synchronization. A healthy Supabase Auth service and reachable catalogue Edge Functions do not mean the app has user authentication or cloud sync.

## Build and verify

Requirements: Flutter 3.27.4 and Java 17 (as used by CI).

```sh
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build apk --release
```

The universal APK is written to `build/app/outputs/flutter-apk/app-release.apk`. The GitHub Actions workflow also installs it on an Android emulator, verifies the app launches, and uploads a genuine emulator screenshot. CI artifacts are named `flix-universal-apk` and `flix-readme-screenshot`. The APK is CI/debug-signed; configure a managed release keystore before store distribution.

## Crash reports

The original post-install crash has not been diagnosed because no affected device/Android version or crash trace was supplied. The emulator smoke test checks this build's install and launch path, but cannot establish the cause on another device. Capture a device trace with:

```sh
adb logcat -c
adb shell monkey -p com.halluyapp.flix 1
adb logcat -d -v time > flix-logcat.txt
```

Share the device model, Android version, and the relevant `FATAL EXCEPTION` or native crash lines to diagnose that report.
