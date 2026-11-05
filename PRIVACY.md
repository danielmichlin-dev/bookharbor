# Privacy design

BookHarbor contacts Plex only after you request linking/discovery, browsing, streaming
or downloads. It includes no analytics or crash-reporting SDK and no hardcoded private
server address, username, account identifier or credential. External book-metadata
lookup is deferred and sends no requests in this version.

Account/server tokens, discovered selected server origins, client identity and saved
resume request blobs use Keychain generic-password entries with
AfterFirstUnlockThisDeviceOnly accessibility. There are no token/password entry fields;
sign-in happens on Plex's website in the browser. Server/library/book names are visible
in the app: do not share screenshots containing private metadata.
Keychain entries may survive uninstall; use Sign out on this iPhone before removing
the app when you want to delete them. Access depends on the signing identity, so
changing the Apple account or app identifier can make existing entries inaccessible.

Imported/downloaded media, artwork, chapters, titles and progress stay in Application Support
folder. The folder is excluded from device backups and uses file protection that
permits playback after the device has been unlocked once. Uninstalling deletes that
folder. No credentials are stored in the local JSON index or UserDefaults.

Only HTTPS connections returned by authenticated Plex resource discovery are eligible.
The selected server must match its discovered machine identity. System TLS certificate
validation remains enabled, HTTP connections are unsupported, and no ATS exception is
added. Tokens are request headers, never URL parameters. Every session carrying authentication rejects
redirects; server-supplied media/artwork keys must be root-relative paths on the selected
origin. AVPlayer's custom resource loader sends authenticated, bounded range requests;
AVFoundation never receives a token-bearing network URL. Underlying errors/responses
and URLs are not logged or shown. Authenticated downloads use an in-process session and pause/checkpoint when the app
enters the background. Apple background sessions always follow redirects, so they are
not used for authenticated transfers. An empty lifecycle scaffold is retained for later
work. App-persisted resumable request blobs are protected in Keychain and cleared at
sign-out. Completed media and local progress remain after sign-out.

The server and Plex account service necessarily see their requests and client identity.
Streaming range requests can reveal listening activity to the server administrator.
No timeline/progress writes to Plex are implemented. No private credentials, media,
library fixtures or listening history belong in CI, source, artifacts or public issues.

Before publication, inspect all intended files, staged diffs, every existing commit,
and Git author metadata. The included pattern scanner is a limited guardrail, not a
guarantee. If a real secret is committed, rotate it and clean history before pushing.
Runtime data, screenshots and audio files must not be copied into this repository.
