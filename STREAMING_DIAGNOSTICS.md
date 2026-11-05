# Streaming diagnosis and safe device evidence

## What is established in source

The old path created an AVPlayerItem, immediately awaited an exact seek (even to zero), and only called play if that seek returned true. It did not observe readiness to trigger a later restore, and a false completion did not produce an error. AVPlayer status failures replaced HTTP/range/authentication errors with a generic file message. The custom loader required an exact Content-Range end matching the requested end, so it rejected an otherwise consistent shorter range instead of continuing. A regression fixture demonstrates that rejection. These are confirmed code defects; none proves which defect caused the owner's specific Plex failure.

The revised path observes item readiness, restores once when ready, preserves the stored checkpoint during loading/failure, separates content probes from data requests, validates and continues shorter ranges, and reports sanitized stages and HTTP/network/AVPlayer numeric codes. Tests generate audio at runtime and run through the real AVPlayer/custom-resource-loader pipeline with synthetic HTTP responses. These tests cannot prove the real server connection, format or iPhone background route works. No private server or audiobook is accessed in CI.

## If version 0.3 streaming still fails

1. On the iPhone, open Home, tap one Plex cover and wait for either playback or a visible failure (preparation times out after 40 seconds).
2. Tap the stethoscope in the player to open Playback diagnostics.
3. Tap Copy sanitized report. Send only that copied report, plus whether this was Wi-Fi or cellular, MP3 or M4B, and whether a complete local download of the same book plays. Do not send book titles, screenshots of the shelf, server addresses, account information, headers, raw iOS console output, credentials or media files.
4. Repeat with one other format only if needed. Every new cover selection clears the previous trace, so copy the failing trace before selecting another book.

The report contains only fixed stage/fact names and integer codes. It excludes book/server/client identifiers, titles, URLs, response bodies, tokens, filenames, timestamps and listening offsets. It stays in RAM, is not automatically sent anywhere, is not written to a log, and is copied only by an explicit button tap. HTTP 401/403/498 suggests rejected authorization/access; 3xx means a blocked redirect; network -1009 typically indicates no network connection. readiness timeout after http/range success points toward format/item preparation; a seek failure after readiness isolates restore. Do not weaken TLS or disable the redirect guard to troubleshoot.

## Ongoing limitations

Only original compatible media is streamed. No HTTP-only connection, token URL, custom certificate bypass, transcode fallback or Pi modification is allowed. Downloads remain foreground-only and checkpoint when the app backgrounds. Plex progress synchronization and external metadata enrichment/manual cover editing remain deferred; METADATA_PLAN.md retains the provider, consent and exact-edition chapter requirements.
