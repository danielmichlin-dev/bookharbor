# BookHarbor — native iPhone audiobook starter

Version 0.1 is an offline playback prototype, not a finished Plex client.

## Included

- SwiftUI iPhone app, iOS 17 or later.
- Import unprotected M4B, M4A, MP3, AAC, or WAV files from the Files picker.
- Local copies retained in Application Support, not disposable browser storage.
- Resume position saved every five seconds and on pause/background transitions.
- Playback speed, 15-second rewind, 30-second forward, and sleep timer.
- Background audio configuration, lock-screen metadata and remote play/pause/skip controls.
- Pause when the output device disconnects or an audio interruption begins.
- Private Keychain fields for future Plex integration. No network requests yet.
- Unsigned device IPA build workflow for local signing with Sideloadly.
- Source and Git history privacy checks.

## Not implemented yet

Plex authentication/linking, server discovery, browsing, streaming, downloads from Plex,
download progress/resume, artwork, embedded chapters, bookmarks, multipart books, and
Plex position synchronization. The current Import button copies an existing file into
the app; it is not a Plex download button. HTTPS-only settings are a placeholder;
local-network/VPN connection policy needs to be designed before Plex integration.

## Validation status

Source and configuration reviewed in a Linux environment; privacy checks run locally.
No Xcode compiler or iPhone was available. First successful GitHub Actions build and
real-device acceptance tests are required. Do not assume compilation or sideloading
has already succeeded. Large-file import currently copies synchronously and may pause
the UI; a coordinated background import is a follow-up before production use.

## Windows setup

See WINDOWS_SETUP.md. Public source is authorized for this project, but this ZIP has
not been published and no GitHub account was accessed. Use a new empty repository;
do not upload your existing Pi workspace. No Apple signing credentials belong in CI.

## First device acceptance test

1. Install the unsigned IPA through Sideloadly using a free Apple account.
2. Import a short, unprotected audio file. Verify play, pause, skips, speed and timer.
3. Pause midway, close/relaunch the app and verify resume position.
4. Enable airplane mode and verify local playback; re-enable Bluetooth if needed.
5. Lock the phone and verify uninterrupted audio and lock-screen controls.
6. Connect AirPods or car Bluetooth. Check sound and supported accessory buttons.
7. Disconnect the headphones and confirm playback pauses instead of playing aloud.
8. Receive a call and confirm playback pauses. Resume manually afterward.
9. Refresh signing using the same Apple account and bundle identifier without
   uninstalling; verify the local book and position remain intact.
10. Test a multi-hour M4B for seeking, storage and reliable long playback.

No dedicated CarPlay interface or entitlement is included. Car Bluetooth is the
initial car-listening target. Any CarPlay Now Playing behavior needs device testing.
Signing expiry prevents the app from opening even when all media is offline.

## Next milestones

1. Prove build, installation, offline audio, background behavior and refresh persistence.
2. Plex link/login on the device; browse one selected audiobook library. Never embed a token.
3. Stream and download original compatible media; add retry, cancellation, validation,
   storage management and reliable background transfers. Avoid transcoding by default.
4. Chapters, artwork, bookmarks, multipart ordering, and local/Plex progress conflicts.

## Technical references

- https://developer.apple.com/documentation/avfaudio/avaudiosession
- https://developer.plex.tv/pms/
- https://github.com/yonaskolb/XcodeGen
- https://sideloadly.io/faq.html
- https://docs.github.com/en/billing/concepts/product-billing/github-actions
