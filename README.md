# BookHarbor

Native iPhone audiobook player for Plex, iOS 17+. Public source; private connection and library data belong only on the iPhone. No Pi or original media changes.

## Status

The previous version built an unsigned IPA and installed with Sideloadly. MP3 import, playback, and locked-iPhone playback were verified on a real iPhone by the owner. Version 0.2 adds a Plex preview; its compile/test status is tracked below. New Plex, download, chapter, Bluetooth, renewal, and migration behavior needs real-iPhone acceptance testing. Compilation is not device validation.

## Version 0.3 bookshelf and streaming work

Device observations from the owner: installing/updating, preservation of imported files, imported MP3 playback with the phone locked, Plex linking and library browsing work. Version 0.2 Plex streaming did not start. Version 0.3 is under automated validation; successful real-device streaming is NOT yet verified.

Home now automatically caches every album page from the selected Plex music library, without fetching audio. It shows a searchable cover grid, multiple Continue Listening books, progress and complete/partial/offline status. Imports remain in Library and Imports; completed Plex copies are also accessible under Downloads across library selections. The selection persists locally. Refresh merges metadata using existing server/album identity and records library identity without replacing UUIDs, track files, chapters, completion state or listening positions. Missing/removed server entries are retained in the cache rather than deleting user data. Search covers cached titles/authors and broadens as automatic pagination completes.

A cover tap resolves tracks lazily and immediately opens/resumes the book, preferring complete local copies. Partial downloads are clearly distinguished and playback still uses streaming until all files complete. Context menus, details and the player provide download actions; removal leaves Plex entries and progress intact. Artwork is fetched only for visible cards, bounded to four concurrent requests, cached locally and downsampled away from the main thread. No audio is downloaded to populate Home.

The streaming path now waits for item readiness before restoring a nonzero position, skips an unnecessary seek to zero, handles failed/interrupted seeks explicitly, and shows Loading, Buffering, Playing, Paused and Failed states. Content-information probes are separate from media-data loading; consistent short byte ranges are accepted and continued, and MPEG-4 audiobook content uses an audio content type. Original-media requests use an audio-appropriate Accept header. Certificate validation, same-origin key validation and redirect refusal remain enabled. There is still no transcoding or automatic connection failover.

The exact cause on the owner's Plex/iPhone remains unconfirmed without device diagnostics. Code inspection established the previous unready-seek/silent-failure path, loss of HTTP error detail and rejection of consistent short ranges. Synthetic AVPlayer integration tests now exercise delayed remote readiness, range loading, resume/chapter seeking and generated WAV/AAC media. See STREAMING_DIAGNOSTICS.md for evidence and the exact safe report to collect if playback still fails.

Current version 0.3 automated build status: pending. Previous successful version 0.2 checks are retained below as historical evidence, not validation of this revision.

## Implemented in the Plex preview

- Browser-based Plex PIN account linking; no manually copied token or password field. Tokens and validated server connections use device-only Keychain storage. Sign-out cancels transfers, clears saved Plex credentials, and retains completed audio and progress. Revoke the authorized device in Plex to revoke server-side access.
- Authorized server discovery with HTTPS only, local secure connections preferred, relay last. Server identity checked against discovery. No TLS bypass or insecure-network exception. HTTP-only servers cannot connect. Expired/revoked access and unreachable servers show retry/link guidance.
- Paged music-library albums as books, with author and optional cached artwork. Track ordering uses disc number then track number. Single-track M4B albums and multi-track albums are supported; libraries must have correct album/disc/track tags. Arbitrary audiobook agents and non-music libraries are not supported yet. We have not inspected private server metadata.
- Direct original MP3/M4A/M4B/MP4/AAC/WAV audio; no transcoding load added. Streaming uses AVPlayer with a custom resource loader and authenticated bounded HTTPS range requests. Servers must support byte ranges. All redirects and absolute server-supplied media URLs are rejected. Incompatible codecs/DRM can still fail playback.
- Independent book progress keyed by server machine identity plus Plex album rating key, unaffected by local title edits. File identity/index, precise offset, chapter ID and update time persist locally; intentional rewinds win. Checkpoints every five seconds and on pause/app background. Abrupt termination can lose up to the checkpoint interval. Plex database rebuilds that change rating keys cannot be automatically reconciled.
- Continue Listening with multiple books, mark finished/unfinished, explicit restart. No server progress synchronization: older server state cannot overwrite offline listening.
- Persistent download queue with progress, pause/cancel/retry, Keychain-protected resume data where usable, ordered multipart completion, HTTP/MIME/size/audio validation and storage headroom checks. Authenticated downloads use an in-process redirect-blocking URLSession, not the background daemon. Keep the app open: downloads pause and checkpoint when it enters the background. Each part commits independently; a book is offline only after every part completes. A non-resumable or changed-credential retry restarts the affected part. Unattended background downloads are NOT implemented: Apple background sessions always follow redirects and cannot enforce the required credential-forwarding policy. An empty background-session lifecycle scaffold is retained, but never schedules authenticated transfers. A runtime guard and regression test prevent authenticated scheduling on background configurations. Relaunch and Retry resumes where supported or restarts only the incomplete file.
- Offline books use persistent Application Support storage and require no Plex login. Local audio deletion retains Plex metadata/progress. Long-press shelf books for actions. Storage total includes validated partial tracks. Imported books retain the previous index, UUIDs, filenames and positions; deleting an imported book explicitly deletes its progress.
- Plex chapters plus AVFoundation embedded chapters, with chapter titles/start/end, durations, current chapter and tap-to-jump. File boundaries have a separate ordered track list. Missing chapter data never blocks audio. Embedded chapters are read when a file is opened and during download validation; cached chapter metadata is available offline. No external or invented chapter timings.
- Existing speed, sleep timer, audio session, lock-screen controls and disconnect/interruption handling retained. No dedicated CarPlay interface or entitlement.

## Validation

Final [GitHub Actions run 41955563692](https://github.com/danielmichlin-dev/bookharbor/actions/runs/41955563692) passed all 13 simulator tests with zero failures and compiled/packaged the unsigned iPhone IPA on macOS-15. The downloaded IPA was inspected: version 0.2.0/build 2, original bundle identifier org.example.bookharbor, audio background mode, no ATS exception, no bundled media/runtime library/test bundle/provisioning profile, and no code signature. Simulator tests use free ad-hoc signing; the deliverable IPA is unsigned. New Plex/device behavior remains unverified on a real iPhone. Synthetic XCTest coverage includes Plex parsing/order, malformed chapter timing, multipart navigation, URL/authentication policy, redirect rejection, HTTP/size/MIME completion failures, legacy-index migration, Keychain roundtrip and two independent book positions after relaunch (including rewind, metadata edit, and download-state changes).

Tests do not substitute for real background transfers, embedded chapter extraction across formats, TLS/server compatibility or iPhone audio routing. No private credentials, media or library fixtures are used in CI. The standard macOS runner builds an unsigned device IPA after simulator tests; artifact retention is one day. No paid service or Apple membership is required by the build.

## Install / update on Windows

Use GitHub CLI in PowerShell (artifact expires after one day). Download this verified build:

```powershell
gh run download 41955563692 --repo danielmichlin-dev/bookharbor --name BookHarbor-unsigned --dir .\build\ipa-41955563692
```

Open `build\ipa-41955563692\BookHarbor-unsigned.ipa` in Sideloadly. Connect and trust the iPhone. Use the **same Apple Account and the same Sideloadly app/bundle identifier used for the installed copy**, and install over it. Source bundle identity remains `org.example.bookharbor`; preserve any identifier Sideloadly previously assigned. **Do not uninstall.** Verify the existing imported file and progress afterward. Free signing needs periodic renewal (normally seven days); an expired app cannot open even with offline media. See WINDOWS_SETUP.md for initial setup.

## Real-iPhone checklist

1. Before updating, note two existing positions privately. Update without uninstalling; verify imported audio, both positions and Continue Listening.
2. Link in Plex browser, return to BookHarbor, discover/select server and audiobook music library. Browse multiple pages; check book grouping, author, cover and disc/track order. Do not send private connection data to chat or issues.
3. Stream a single M4B and a multi-track MP3 book. Check seeking across files, speed and timer. Check Plex/embedded chapter titles, durations, current chapter and jump. With no chapters, verify the track list and audio still work.
4. Switch A to B, intentionally rewind A, quit/relaunch and reboot. Restore both positions within the checkpoint interval, including a position inside a chapter. Download A and confirm progress is unchanged when opening its local copy.
5. Start a download, background/lock the phone, and verify it pauses safely. Reopen and Retry to continue. Pause/resume, cancel/retry, interrupt Wi-Fi and test authorization failure. No error or partial book should show Offline. Check storage reporting and local deletion.
6. Complete all parts, sign out, enable airplane mode, relaunch and play all tracks. Verify cached artwork/chapters and progress with no fresh login.
7. Check locked-screen audio and play/pause/skip, AirPods/car Bluetooth, disconnect pause, call interruption and manual resume. Refresh signing again without uninstalling and check data remains.
8. Mark finished/unfinished; confirm position stays until explicit Restart. Check Restart returns to the first file and beginning.

## Deferred

Unattended background downloads (blocked by the redirect/authentication constraint), Plex progress sync, automatic reconnection/failover during a stream, transcoding, bookmarks, external metadata search/candidate selection, manual metadata/cover editing, and external edition-matched chapter lookup. PIN linking currently uses Plex's documented legacy token flow; short-lived JWT migration/refresh is deferred. See METADATA_PLAN.md for provider research and privacy rules. No metadata provider requests are currently made. Large Files imports still copy synchronously as in the verified starter.

## References

- Plex API/authentication: https://developer.plex.tv/pms/
- Apple background transfers: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- Sideloadly FAQ: https://sideloadly.io/faq.html

Apple documents the background redirect limitation here: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background . No private token may be sent through that transport until a documented safe authentication mechanism has been verified.
