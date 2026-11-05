# Local metadata enrichment: later milestone

Core Plex playback/download/progress takes priority. No external lookup, silent replacement, manual details editor or cover picker is shipped in 0.2.

## Provider research

Reviewed official documentation during this implementation:

- Open Library APIs: https://openlibrary.org/developers/api and https://openlibrary.org/dev/docs/api/search. Suitable for user-triggered title/author searches and work/edition candidates. No paid subscription or API key is described. The service asks applications to register their use case, identify requests with a User-Agent and contact email, cache responses, avoid scraping/bulk use, and follow rate limits. A project contact/registration decision must precede integration; personal contact details must not be committed. Do not use it as a bulk backend.
- Covers: https://openlibrary.org/dev/docs/api/covers. Cover ID and edition identifiers are supported; missing covers can return 404 with default=false. Observe cover guidelines, rate limiting and a courtesy attribution link. Verify caching/licensing conditions for the intended native offline use before shipping.
- Google Books: https://developers.google.com/books/docs/v1/using and https://developers.google.com/books/docs/v1/reference/volumes. Public requests require an API key or OAuth identification under the documented policy. This adds credential/quota configuration; it is not selected for this milestone and no paid project is created. Any future provider credential must be entered in the app and stored in Keychain, never packaged in an IPA.

These bibliographic catalogs do not establish exact audiobook editions, narrators, runtime, series completeness or timed chapters. Publication dates can describe a print edition rather than the audiobook. Do not imply those fields are supplied when absent. No accurate timed-chapter provider has been selected.

## Required future behavior

Use Plex first. An explicit Find book details action must disclose that the entered title/author query is sent to the chosen provider. No automatic library upload or history transfer. Show work and edition candidates, identifiers and provenance so the user selects the correct match. Preview changes field by field, preserve good existing metadata, and allow manual title/author/description/publication/series corrections and cover choice. Cache the chosen details and image locally for offline use and preserve stable book/progress identities. Never rename server files or write back to Plex.

Chapter timings require verified matching edition, narrator and runtime; generic tables of contents are not timed chapters. Never import guessed/different-edition timestamps. Prefer exact Plex/embedded chapters and clearly show chapter information unavailable or the separate track list when absent. Add cache, candidate-selection, privacy and edition-mismatch tests before enabling lookup.
