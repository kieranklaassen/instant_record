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
The server-rendered slot above the oldest message. It shows the state of history loading (idle, loading, offline, beginning reached) and is changed in place, so the list never shifts. It does not trigger the load; scrolling near the top does.

### Prefetch margin
How close to the top of the message scroller (in CSS pixels) the reader must be before the next older page loads. A constant in the conversation controller.

## Flagged ambiguities

- An early Slack demo plan preferred "HTML+Rails only" and rejected Stimulus controllers; demo UI JS now conventionally uses Stimulus. The plan's anti-Stimulus stance is historical for that decision record, not current guidance.
