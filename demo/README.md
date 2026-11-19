# InstantRecord demos

```sh
bin/rails db:prepare
bin/rails server
```

Every demo is Hotwire with no build step, except the Inbox, which is an
Inertia page in React (`app/frontend`), built on the gem's own package in
`../frontend`. Its bundle is built by Vite into
`app/assets/builds/inbox.js`:

```sh
npm install
npm run build   # once, or `npm run dev` to rebuild on change
npm test        # the keyboard hook's unit tests
```

`bin/rails test` and `bin/rails assets:precompile` build it first.

## The Assistant

A chat and each of its turns are synced records (`AssistantChat`,
`AssistantTurn`), drawn by the same ERB in Rails and in the compiled browser
runtime. A question is saved the moment it is asked, online or off, and the
answer is written onto the same record by whoever was asked. The switch in the
composer (Auto, Server, On-device) chooses who that is. The page's script holds
no conversation state: it sends writes, folds the views' answer into the page,
and talks to the browser's model.

Chats are shared by every visitor, like Chat's messages, so a prompt typed here
is public. The newest 40 visitor chats are kept
(`Assistant::ReplyJob::KEPT_CHATS`); the three examples are seeded by
`db/seeds/assistant_chats.rb`.

**Server.** A `server_only` callback on `AssistantTurn` enqueues
`Assistant::ReplyJob`, which writes Rails' answer onto the turn. The change log
carries it to every browser. This holds for a turn posted to Rails and for one a
browser saved offline and synced later. The job asks a model through
[RubyLLM](https://rubyllm.com) (`app/models/assistant/reply.rb`) when one of
these is set:

| Variable | Model asked |
|---|---|
| `ANTHROPIC_API_KEY` | `claude-haiku-5-5` |
| `OPENAI_API_KEY` | `gpt-5.4-mini` |
| `GEMINI_API_KEY` | `gemini-3.1-flash-lite` |

`ASSISTANT_MODEL` names another model RubyLLM knows. With a key set, a visitor's
prompt and the last six answered turns of the chat are sent to that provider.
With no key the scripted guide (`app/models/assistant/guide.rb`) answers, and it
also answers when the call fails or after `ASSISTANT_DAILY_LIMIT` model calls in
a day (500 by default). That count lives in `Rails.cache`, so it is as wide as
the cache store: with the default file store it is per machine and starts again
when `tmp/` is cleared, and a store that cannot count allows no model call. A
turn can reach Rails from any browser's outbox, so that count is what bounds
spending. A reply may look at the workspace once, and the whole call has 30
seconds.

**On-device.** The page asks the browser's built-in model through Chrome's
Prompt API (`app/javascript/controllers/assistant_local_model.js`), which is
Gemini Nano on desktop Chrome, and saves the reply onto the turn. The model
runs on the device, but the turn is a record: it syncs to Rails like any other.
Choosing On-device downloads the model the first time. In a browser without the
API the option is off.

Only Rails ever calls a provider. The compiled site holds no key and no
RubyLLM code: `compiled/pipeline/carve.py` leaves the initializer,
`app/models/assistant` and `app/jobs/assistant` out of the build
(`test/compiled_carve_test.rb` fails if a file that uses RubyLLM is carried in),
and the browser has no endpoint that returns a reply. It writes a turn, and the
answer arrives through sync.

**Auto** asks Rails when online and the browser's model when offline. Offline
in a browser with no model, the question waits in the outbox and Rails answers
once it syncs.
