# BookHarbor

Native iPhone audiobook player for Plex, iOS 17+. Public source; private connection and library data belong only on the iPhone. No Pi or original media changes.

## Status

The previous version built an unsigned IPA and installed with Sideloadly. MP3 import, playback, and locked-iPhone playback were verified on a real iPhone by the owner. Version 0.2 adds a Plex preview; its compile/test status is tracked below. New Plex, download, chapter, Bluetooth, renewal, and migration behavior needs real-iPhone acceptance testing. Compilation is not device validation.

## Implemented in the Plex preview

- Browser-based Plex PIN account linking; no manually copied token or password field. Tokens and validated server connections use device-only Keychain storage. Sign-out cancels transfers, clears saved Plex credentials, and retains completed audio and progress. Revoke the authorized device in Plex to revoke server-side access.
- Authorized server discovery with HTTPS only, local secure connections preferred, relay last. Server identity checked against discovery. No TLS bypass or insecure-network exception. HTTP-only servers cannot connect. Expired/revoked access and unreachable servers show retry/link guidance.
- Paged music-library albums as books, with author and optional cached artwork. Track ordering uses disc number then track number. Single-track M4B albums and multi-track albums are supported; libraries must have correct album/disc/track tags. Arbitrary audiobook agents and non-music libraries are not supported yet. We have not inspected private server metadata.
- Direct original MP3/M4A/M4B/MP4/AAC/WAV audio; no transcoding load added. Streaming uses AVPlayer with a custom resource loader and authenticated bounded HTTPS range requests. Servers must support byte ranges. All redirects and absolute server-supplied media URLs are rejected. Incompatible codecs/DRM can still fail playback.
- Independent book progress keyed by server machine identity plus Plex album rating key, unaffected by local title edits. File identity/index, precise offset, chapter ID and update time persist locally; intentional rewinds win. Checkpoints every five seconds and on pause/app background. Abrupt termination can lose up to the checkpoint interval. Plex database rebuilds that change rating keys cannot be automatically reconciled.
- Continue Listening with multiple books, mark finished/unfinished, explicit restart. No server progress synchronization: older server state cannot overwrite offline listening.
- Persistent background URLSession downloads, progress, pause/cancel/retry, system resume data where usable, ordered multipart completion, HTTP/MIME/size/audio validation and storage headroom checks. Each part commits independently; a book is offline only after every part completes. A non-resumable or changed-credential retry restarts the affected part. iOS controls background scheduling; force-quitting prevents background relaunch until manually reopened.
- Offline books use persistent Application Support storage and require no Plex login. Local audio deletion retains Plex metadata/progress. Long-press shelf books for actions. Storage total includes validated partial tracks. Imported books retain the previous index, UUIDs, filenames and positions; deleting an imported book explicitly deletes its progress.
- Plex chapters plus AVFoundation embedded chapters, with chapter titles/start/end, durations, current chapter and tap-to-jump. File boundaries have a separate ordered track list. Missing chapter data never blocks audio. Embedded chapters are read when a file is opened; cached chapter metadata is available offline. No external or invented chapter timings.
- Existing speed, sleep timer, audio session, lock-screen controls and disconnect/interruption handling retained. No dedicated CarPlay interface or entitlement.

## Validation

Pending the first version 0.2 macOS run. Synthetic XCTest coverage includes Plex parsing/order, malformed chapter timing, multipart navigation, URL/authentication policy, redirect rejection, HTTP/size/MIME completion failures, legacy-index migration, Keychain roundtrip and two independent book positions after relaunch (including rewind, metadata edit, and download-state changes).

Tests do not substitute for real background transfers, embedded chapter extraction across formats, TLS/server compatibility or iPhone audio routing. No private credentials, media or library fixtures are used in CI. The standard macOS runner builds an unsigned device IPA after simulator tests; artifact retention is one day. No paid service or Apple membership is required by the build.

## Install / update on Windows

Use GitHub CLI in PowerShell (artifact expires after one day):

```powershell
$runId = gh run list --repo danielmichlin-dev/bookharbor --workflow build.yml --branch main --status success --limit 1 --json databaseId --jq '.[0].databaseId'
gh run download $runId --repo danielmichlin-dev/bookharbor --name BookHarbor-unsigned --dir .\build\latest-ipa
```

Open `build\latest-ipa\BookHarbor-unsigned.ipa` in Sideloadly. Connect and trust the iPhone. Use the **same Apple Account and the same Sideloadly app/bundle identifier used for the installed copy**, and install over it. Source bundle identity remains `org.example.bookharbor`; preserve any identifier Sideloadly previously assigned. **Do not uninstall.** Verify the existing imported file and progress afterward. Free signing needs periodic renewal (normally seven days); an expired app cannot open even with offline media. See WINDOWS_SETUP.md for initial setup.

## Real-iPhone checklist

1. Before updating, note two existing positions privately. Update without uninstalling; verify imported audio, both positions and Continue Listening.
2. Link in Plex browser, return to BookHarbor, discover/select server and audiobook music library. Browse multiple pages; check book grouping, author, cover and disc/track order. Do not send private connection data to chat or issues.
3. Stream a single M4B and a multi-track MP3 book. Check seeking across files, speed and timer. Check Plex/embedded chapter titles, durations, current chapter and jump. With no chapters, verify the track list and audio still work.
4. Switch A to B, intentionally rewind A, quit/relaunch and reboot. Restore both positions within the checkpoint interval, including a position inside a chapter. Download A and confirm progress is unchanged when opening its local copy.
5. Download with the phone locked; background and reopen during transfer. Pause/resume, cancel/retry, interrupt Wi-Fi and test authorization failure. No error or partial book should show Offline. Check storage reporting and local deletion.
6. Complete all parts, sign out, enable airplane mode, relaunch and play all tracks. Verify cached artwork/chapters and progress with no fresh login.
7. Check locked-screen audio and play/pause/skip, AirPods/car Bluetooth, disconnect pause, call interruption and manual resume. Refresh signing again without uninstalling and check data remains.
8. Mark finished/unfinished; confirm position stays until explicit Restart. Check Restart returns to the first file and beginning.

## Deferred

Plex progress sync, automatic reconnection/failover during a stream, transcoding, bookmarks, external metadata search/candidate selection, manual metadata/cover editing, and external edition-matched chapter lookup. See METADATA_PLAN.md for provider research and privacy rules. No metadata provider requests are currently made. Large Files imports still copy synchronously as in the verified starter.

## References

- Plex API/authentication: https://developer.plex.tv/pms/
- Apple background transfers: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- Sideloadly FAQ: https://sideloadly.io/faq.html
