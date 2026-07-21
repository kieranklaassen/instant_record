# InstantRecord

Rails models that run in the browser, sync to your server, and keep working offline.

InstantRecord boots real Active Record inside the browser with [ruby.wasm](https://github.com/ruby/ruby.wasm) and [wasmify-rails](https://github.com/palkan/wasmify-rails), persists to [PGlite](https://pglite.dev) — Postgres compiled to Wasm — and writes optimistically through a durable outbox that syncs to a Rails + Postgres server. The same model classes run on both sides, against the same Postgres dialect on both sides.

:construction: This is a spike. The API below is the target, not a promise.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "instant_record"
```

The browser bundle — ruby.wasm, PGlite, and your syncable models — is built by wasmify-rails:

```sh
bundle exec rails instant_record:build
```

## How It Works

The same `app/models/issue.rb` loads in two places:

- **In the browser**, under ruby.wasm, against a PGlite database persisted locally
- **On the server**, under CRuby, against Postgres

A `Syncable` concern gives models an id that is stable across both, records every local change to an outbox in the same transaction as the write, and replays that outbox to the server. The server streams changes back over [SSE](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events). Reads and writes in the browser are local; the network is never in the hot path.

## Getting Started

Make a model syncable. This is the whole opt-in:

```ruby
class Issue < ApplicationRecord
  include InstantRecord::Syncable
end
```

In the browser, use it like Active Record, because it is:

```ruby
issue = Issue.create!(title: "Ship the spike", state: "open")

issue.update!(state: "closed")

Issue.where(state: "open").order(created_at: :desc).to_a
```

Every write commits to local PGlite immediately and enqueues a mutation. Your UI renders from the local database and never waits on the server.

## The Outbox

Each write records the change and a mutation in one local transaction:

```ruby
Issue.transaction do
  issue.update!(state: "closed")
  # InstantRecord writes the outbox row here, atomically
end
```

If the tab closes before the mutation syncs, it is still on disk on reload. The outbox drains in order when the connection returns:

```ruby
InstantRecord.sync            # drain the outbox, then catch up on remote changes
InstantRecord.pending_count   # mutations not yet acknowledged
```

## Sync

Point the client at your server and start the stream:

```ruby
InstantRecord.configure do |config|
  config.endpoint = "https://example.com/instant_record"
  config.models = [Issue, Todo]
end

InstantRecord.start   # POSTs the outbox, opens the SSE stream, applies remote changes
```

Writes go up as HTTP POST. Changes come down over a single SSE stream with a cursor, so a dropped connection resumes from the last change it saw instead of refetching everything.

On the server, mount the engine and expose the syncable models:

```ruby
# config/routes.rb
mount InstantRecord::Engine, at: "/instant_record"
```

```ruby
# config/initializers/instant_record.rb
InstantRecord.sync Issue, Todo
```

## Conflicts

The default is last-write-wins by `updated_at`. The most recent write for a row wins; older writes for that row are discarded on both sides. No configuration required.

```ruby
class Issue < ApplicationRecord
  include InstantRecord::Syncable
  # last-write-wins by default
end
```

A model-level DSL for smarter merges is sketched but out of scope for the spike:

```ruby
# Not implemented yet
class Issue < ApplicationRecord
  include InstantRecord::Syncable
  resolves_conflict_on :state, prefer: :closed
end
```

## What's Not Included

The spike is deliberately narrow. Out of scope, on purpose:

- CRDTs and operational transforms — last-write-wins is the only strategy
- Postgres logical replication — sync is application-level, over HTTP and SSE
- Multi-tab leader election — one tab owns the database for now
- Attachments and large blobs
- Authentication and authorization on the sync endpoint

## Reference

The spike is a bet on three things, in order of risk:

1. **Boot.** Full Active Record plus PGlite under ruby.wasm in a Worker has to load fast enough and small enough to be usable. PGlite is async-only, so Ruby runs on an asyncified build through `evalAsync`. This is the first kill-gate — if it fails, nothing downstream matters.
2. **Persistence.** PGlite survives reloads and holds a real schema.
3. **Sync.** The outbox, POST, and SSE cursor round-trip correctly, and the shared model classes behave identically against browser PGlite and server Postgres.

PGlite in the browser means one Postgres dialect end-to-end. If its async-only execution or bundle size bites, [SQLite Wasm](https://sqlite.org/wasm) via wasmify-rails' `sqlite3_wasm` adapter is the escape hatch — named here so the decision is visible, not chosen.

## History

View the [changelog](CHANGELOG.md).

## Contributing

Everyone is encouraged to help improve this project. Here are a few ways you can help:

- [Report bugs](https://github.com/kieranklaassen/instant_record/issues)
- Fix bugs and [submit pull requests](https://github.com/kieranklaassen/instant_record/pulls)
- Write, clarify, or fix documentation
- Suggest or add new features

To get started with development:

```sh
git clone https://github.com/kieranklaassen/instant_record.git
cd instant_record
bundle install
bundle exec rake test
```
