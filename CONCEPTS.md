# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## InstantRecord sync

### Sync window
The newest contiguous slice of a syncable model's rows that a fresh client receives. Older pages are not in the initial bootstrap; they load on demand (for example when the visitor scrolls up in a conversation). Declared on the model with a positive limit and optional partition key.

### History page
One keyset-paginated batch of older records fetched into the local database after the sync window, keyed by a composite cursor (typically created-at plus id). Serving a history page may hit the real server only when the page is not already contiguous locally.

### Fragment contract
The server-rendered HTML partial (and its data attributes) that both the server runtime and the browser runtime use as the single shape for conversation state. Client JS reads cursors and "has more" from those attributes rather than inventing a parallel JSON API for the demo UI.

## Demo conversation UI

### History sentinel
An ephemeral element at the top of the message scroller that an IntersectionObserver watches to trigger loading older history. Prefetch extends the observer's root margin above the viewport so the next page starts loading before the reader hits the top. The sentinel is mounted on Stimulus connect and removed on disconnect so Turbo's page cache does not duplicate it.

### Prefetch margin
How far above the visible message viewport (in CSS pixels) the history sentinel counts as intersecting, so older pages load ahead of the scroll position. Exposed as a Stimulus value on the conversation root so the demo can tune it from the view; zero restores load-only-at-top behavior.

## Flagged ambiguities

- An early Slack demo plan preferred "HTML+Rails only" and rejected Stimulus controllers; demo UI JS now conventionally uses Stimulus. The plan's anti-Stimulus stance is historical for that decision record, not current guidance.
