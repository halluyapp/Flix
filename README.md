# FLIX

Flix is an original Flutter streaming-discovery app for Android. It combines a TMDB catalogue, a verified short-film **Clips** feed, and playback through the configured Zarhosting provider, with its own brand identity and product scope.

The Android-emulator screenshot is produced by CI and published as the `flix-readme-screenshot` workflow artifact.

## What is implemented

- **Home** — trending, top-rated, regional, and genre rails from TMDB.
- **Clips** — a vertical discovery feed built from real Zarhosting catalogue records. An item is included only when the provider marks it as a movie, explicitly tags it with the `Short` genre, and reports `has_resource: true`. Query-only matches, series, and explicit adult genres, flags, or age ratings are excluded. Playback passes the provider's subject ID and slug directly to the existing player rather than guessing a TMDB match.
- **New & Hot** — remains available as a separate bottom-navigation destination.
- **Search and My Flix** — existing discovery and viewer-state screens remain in place.
- **Universal Android package** — CI builds one APK and checks that it contains ARMv7, ARM64, and x86_64 native libraries.

## Supabase backend

Flix's dedicated project is **Flix** (`jewtsdupzwwkdoudwgyk`, `eu-west-2`). The repository is linked to this project in `supabase/config.toml`.

- `supabase/migrations/20261114154911_flix_platform_hardening.sql` defines profiles, watch progress, My List, ratings, profile settings, release reminders, and a server-only stream cache, with row-level security and profile ownership checks. This migration has been applied to the dedicated project.
- `supabase/functions/clips-feed` is deployed and returns provider-backed short-film records after applying the strict metadata filter. The app falls back to the same filter against the provider if Supabase is unavailable.
- `supabase/functions/tmdb-proxy` is deployed with a fixed endpoint allowlist and a per-isolate request limit. TMDB requests are proxied through Supabase so the bearer token is not compiled into the APK. The current `TMDB_READ_TOKEN` is a Supabase Edge Function secret.
- No Supabase API, service-role, or secret key is included in the app. The public Clips endpoint returns catalogue metadata only.

**Credential rotation:** this TMDB read token was present in the repository before this change, so rotate it with TMDB and update the Supabase `TMDB_READ_TOKEN` secret before a public/store release. Removing it from the current Flutter source does not erase prior Git history.

**Viewer-state limitation:** profiles, My List, and watch progress are still stored on-device by the current Flutter app. The Supabase tables and RLS are ready, but account sign-in and cross-device synchronization are not wired into the UI yet. No cloud sync is claimed.

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
