# Privacy design

This prototype makes no network requests and includes no analytics or crash-reporting
SDK. It has no hardcoded server address, username, account identifier or credential.

Server address and token are stored as separate Keychain generic-password entries
using AfterFirstUnlockThisDeviceOnly accessibility. The token field masks its display.
The server field is visible in Settings, so avoid sharing a screenshot of that screen.
Keychain entries may survive uninstall; use Clear saved connection before removing
the app when you want to delete them. Access depends on the signing identity, so
changing the Apple account or app identifier can make existing entries inaccessible.

Imported media, titles and position metadata stay in the app's Application Support
folder. The folder is excluded from device backups and uses file protection that
permits playback after the device has been unlocked once. Uninstalling deletes that
folder. No credentials are stored in the local JSON index or UserDefaults.

Future network work must use authenticated requests to the explicitly selected server,
validate TLS, avoid credential-bearing URLs and reject redirects that could forward
a token to a different host. No credentials in CI, fixtures, exception messages or logs.
The Plex server will necessarily see requests and listening updates when integration
is added; 'private' does not mean hidden from the server administrator.

Before publication, inspect all intended files, staged diffs, every existing commit,
and Git author metadata. The included pattern scanner is a limited guardrail, not a
guarantee. If a real secret is committed, rotate it and clean history before pushing.
Runtime data, screenshots and audio files must not be copied into this repository.
