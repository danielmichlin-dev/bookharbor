# BookHarbor development instructions

Build a native iPhone audiobook app for Plex using Windows/PowerShell development
and free standard GitHub macOS builds. No spending, paid membership, TestFlight,
or dedicated CarPlay entitlement. Car audio uses normal iOS output routing.

The initial milestone is offline import/playback and free sideload installation.
Do not claim Plex integration, compilation, or device testing is complete until
verified. Keep README's status current. Preserve originals on the Plex server.

Never add personal server addresses, credentials, Apple account data, SSH keys,
media files, listening history, personal names or email addresses to source, tests,
logs, issue bodies, screenshots or artifacts. Use Keychain for credentials.
Before publishing inspect staged content and Git history and run the privacy check.
Do not weaken TLS or put tokens in URLs to make playback work.

Use progress updates and realistic time-to-completion estimates for bounded work.
State blockers and uncertainty instead of inventing completion times. Do not add
paid build services or change repository visibility without authorization.

Prioritize meaningful tests for persistence, credential handling, downloads and
resume behavior. Validate on a real iPhone before claiming Bluetooth, background
playback or renewal persistence works. No direct Pi changes are needed initially.
