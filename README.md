# BookHarbor

Native iPhone audiobook app for Plex, iOS 17+. Version **0.3.0, build 3** adds an automatic bookshelf and a traced, readiness-gated streaming path. The public source contains no private connection information or library fixtures. No Pi, Plex installation or original media changes are made.

## Validation status

[GitHub Actions run 41960760253](https://github.com/danielmichlin-dev/bookharbor/actions/runs/41960760253) passed **26 automated tests with zero failures**, then compiled and packaged the unsigned iPhone IPA on the standard macOS-15 runner. Simulator tests use free ad-hoc signing; the device artifact remains unsigned. Artifact retention is one day.

The downloaded IPA was inspected: version 0.3.0/build 3, original `org.example.bookharbor` bundle identity, audio background mode retained, no ATS exception, no code signature/provisioning profile, and no bundled test media, runtime library data or test bundle.

Owner observations on the preceding installed version: Sideloadly installation/updates work, imported files survived, imported MP3 playback works with the iPhone locked, and Plex sign-in/browsing work. Plex streaming did not start. **Version 0.3 real-device streaming is NOT verified yet.** New bookshelf behavior, downloads, chapters, routing and resume behavior need the checklist below. Compilation and synthetic playback tests do not establish real Plex/iPhone compatibility.

## Automatic bookshelf

- Select a Plex server and audiobook music library once. Album pages populate Home automatically, without a per-title Add/Stream/Download step or any audio download. Version 0.2 did not persist the selected library: choose it once after this update; 0.3 retains that selection across launches.
- Searchable cover grid with title, author, progress, complete-download indicator and separate partial-download status. Continue Listening includes multiple in-progress books, ordered by the latest local checkpoint.
- Cover tap plays/resumes directly: use a complete local copy, otherwise resolve tracks and stream. Incomplete copies remain marked partial and require a connection for playback. No Stream/Download chooser appears.
- Library includes selected Plex albums and imports. Imports remain separately accessible; Downloads shows completed Plex copies across library selections. Cached metadata and previously fetched covers remain browsable offline, including after sign-out.
- Pull to refresh album metadata. Refresh merges server/album identity and stores library identity without replacing existing UUIDs, files, positions, completion flags or chapters. Entries absent from a refresh are retained rather than deleting user data. Search covers cached titles/authors and broadens as pagination finishes.
- Artwork loads only for visible cards, with at most four concurrent requests, and is cached privately. Display images are downsampled away from the main thread. Cached covers are not automatically revalidated against later server artwork changes.
- Separate Details button, current-player Chapters/Tracks button, and context menus. Details loads chapter/track metadata on demand without fetching audio. Titles remain Plex music albums; disc then track order determines multipart playback. Non-music audiobook agents/libraries are not supported yet.

## Streaming changes and diagnosis

Source inspection found an immediate seek before readiness, a silent branch when that seek returned false, generic errors masking HTTP/authentication failures, and exact Content-Range matching that rejected a valid shorter response. The latter is reproduced by a regression fixture; the exact cause of the owner's device failure is still unconfirmed.

The revised player observes readiness, restores a nonzero position once the item is ready, avoids an unnecessary seek to zero, and reports interrupted/failed seeks rather than silently suppressing autoplay. Loading, Buffering, Playing, Paused and Failed are visible states. Content-information probing is separate from media loading; consistent short ranges are validated and continued. MPEG-4 audiobook content uses an audio content type. Requests that ignore Range, authentication failures, blocked redirects and network errors retain sanitized numeric status codes.

Tests generate silent WAV and AAC/M4B-style media at runtime and exercise the actual AVPlayer/custom-resource-loader path with synthetic range replies: readiness, playback, precise resume and chapter jumps. They also cover direct shelf tap, metadata resolution, local-copy preference with zero subsequent network requests, failure display, and diagnostic privacy. They do not access a real Plex server.

Tap the player's **stethoscope > Copy sanitized report** if playback fails. The RAM-only report accepts fixed stage/fact names and numeric codes, not URLs, titles, account/server identifiers, tokens, response bodies or listening positions. Send only that report plus Wi-Fi/cellular, MP3/M4B and whether a complete local copy plays. Do not send shelf screenshots or raw device console logs. See [STREAMING_DIAGNOSTICS.md](STREAMING_DIAGNOSTICS.md).

## Privacy and transport

Plex browser PIN linking is retained; no copied token/password is required. Authorized HTTPS connections are discovered, certificate validation stays enabled, and server identity is checked before saving an origin/token in device-only Keychain storage. Tokens remain in request headers, never URLs. Server-supplied media/artwork keys must resolve on the selected origin, and authenticated sessions refuse redirects. AVPlayer receives a private resource scheme, not a credential-bearing network URL. No analytics or external book-metadata searches are enabled.

HTTP-only servers are unsupported; no blanket insecure-network exception is added. Compatible original MP3/M4A/M4B/MP4/AAC/WAV media is used without transcoding. Servers must support valid byte ranges. There is no automatic connection failover, re-resolution of replaced server media, or codec/transcode fallback. Revoked access, rejected requests and unavailable connections produce sanitized errors. Local sign-out cancels transfers/stream selection and clears Plex Keychain settings, while retaining completed books and local progress. Revoke the authorized device in Plex for server-side revocation.

## Downloads, chapters and progress

Download for offline listening is available from context menus, Details and the player. Progress, pause, cancellation, retry/resume where supported, removal and storage totals are available. HTTP/MIME/expected-size/audio validation precedes completion; each multipart file commits independently. A book is available offline only when every part completes. Removing a Plex download retains its shelf entry and progress. Explicit deletion of an imported book removes that imported copy and its progress.

**Keep BookHarbor open during downloads.** Transfers pause/checkpoint when the app backgrounds; Retry resumes where supported or restarts the incomplete part. Unattended background downloading remains deferred: Apple background URLSession tasks always follow redirects and cannot enforce this credential-forwarding policy. The empty lifecycle scaffold never schedules authenticated transfers; a runtime guard and test enforce that restriction. No background-download claim is made. [Apple documentation](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

Local progress stores stable server-qualified book identity, file identity/index, exact offset, chapter ID and checkpoint time. Intentional rewinds replace older positions; the largest position is never treated as the newest. Checkpoints save every five seconds and on pause/background; abrupt termination can lose up to that interval. Old imported indexes, UUIDs and filenames are retained. Plex database rebuilds/replaced media need future reconciliation; no server progress synchronization is enabled.

Plex and embedded chapters retain titles, start/end times and durations, current-chapter indication and jump navigation. Chapters cache locally; file boundaries are shown separately as tracks. Missing chapter metadata never blocks playback and shows Chapter information unavailable. No external or invented timings are used. Existing speed, sleep timer, lock-screen controls and disconnect/interruption pause remain. New streaming/locked-screen/Bluetooth behavior still needs device testing. No dedicated CarPlay interface or entitlement is included.

## Download and update on Windows

Run in PowerShell before the one-day artifact expiry:

```powershell
gh run download 41960760253 --repo danielmichlin-dev/bookharbor --name BookHarbor-unsigned --dir .\build\ipa-41960760253
```

Open `build\ipa-41960760253\BookHarbor-unsigned.ipa` in Sideloadly. Use the **same Apple Account and the same app identifier previously used**, preserving any identifier Sideloadly assigned. Source identity remains `org.example.bookharbor`. Install over the existing app; **do not uninstall**. Check imported files and positions immediately afterward. Free signing needs periodic renewal (normally seven days); expired signing prevents opening even with offline audio. WINDOWS_SETUP.md retains initial setup instructions; do not recreate the existing repository for an update.

## Real-iPhone acceptance checklist

1. Update without uninstalling. Verify imported MP3 files and old positions. Choose the audiobook library once; Home should fill automatically across pages, with lazy covers, search and multiple Continue Listening books.
2. Tap a Plex MP3 and M4B cover directly. Check Loading/Buffering/Playing, actual sound, skips and multipart order. If either fails, copy only the sanitized diagnostic report as described above. Do not interpret a successful build as this test passing.
3. Switch books A/B, intentionally rewind A, relaunch/reboot and verify both exact positions. Test a position inside a chapter and across a file boundary. Test mark finished/unfinished and explicit Restart separately.
4. Download using the context menu and player, keeping the app open. Test progress, cancel/retry, network interruption and background pause/resume. Partial copies must not show complete/offline. Downloading must not reset the listening position.
5. Complete every part, sign out, enable airplane mode and relaunch. Play/resume all files, cached chapters and artwork. Remove the download: the shelf entry and position must remain; tapping it now explains that connection/authorization is needed.
6. Check chapter title/timing, current-chapter highlight and tap-to-jump online/offline. With no accurate chapters, verify the separate track list and uninterrupted playback.
7. Verify locked-screen audio and controls, speed/sleep timer, AirPods/car Bluetooth, disconnect pause and interruptions. Refresh signing again using the same account/identifier without uninstalling, then verify files and positions.

## Deferred

Unattended background downloads, Plex progress synchronization, automatic failover/transcoding, bookmarks, external metadata candidate search/selection, manual corrections/cover selection and exact-edition external chapter lookup. [METADATA_PLAN.md](METADATA_PLAN.md) retains the free-provider research, query-disclosure/consent, local-only cache and exact edition/narrator/runtime requirements. No external provider request or credential is currently used. PIN linking uses Plex's documented legacy flow; JWT refresh/migration is deferred. Large Files imports still copy synchronously as in the verified local prototype.

## References

- Plex API: https://developer.plex.tv/pms/
- Apple resource loading: https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate
- Sideloadly: https://sideloadly.io/faq.html
