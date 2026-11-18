# Shared email inbox demo

## Goal

Add a fifth demo where two people share an inbox and a person can belong to several inboxes. Opening a mailbox selects exactly one sync scope. All identities and mail are fictional and the persona picker is public.

## Implementation

1. Model mail as an append-only stream of messages, replies and archive actions. Persist each inbox's ordered entries under a locked parent. Use the existing InstantRecord bootstrap, mutation and event wire formats. Resolve every server request against the demo membership list. Keep mail outside the public change log and model registry. Retries of the same write return the original result.
2. Render the mailbox through Rails and the compiled app. Use the existing SQLite outbox in the browser. Partition its snapshot, cursor and cross-tab notifications by persona and inbox. Crossing scopes opens a new document. Preserve existing visitor databases during the upgrade.
3. Link both landing pages, seed separate conversations and include the source drawer. Show a public persona picker, an inbox switcher, compose, reply and archive.

## Verification

Test initial download, writes, retries, catch-up and forbidden memberships on Rails. In the compiled browser, queue mail offline, reload, reconnect and observe the other member receive it. Check the other inbox stays isolated. Exercise the existing demo suite and the public landing page.
