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

## The Assistant's models

The Assistant demo answers from two places, and the switch in its composer
(Auto, Server, On-device) chooses between them.

**Server.** Rails asks a model through [RubyLLM](https://rubyllm.com)
(`app/models/assistant/reply.rb`) when one of these is set:

| Variable | Model asked |
|---|---|
| `ANTHROPIC_API_KEY` | `claude-haiku-5-5` |
| `OPENAI_API_KEY` | `gpt-5.4-mini` |
| `GEMINI_API_KEY` | `gemini-3.1-flash-lite` |

`ASSISTANT_MODEL` names another model RubyLLM knows. With a key set, a visitor's
prompt and the last six turns of the conversation are sent to that provider.
With no key the scripted guide (`app/models/assistant/guide.rb`) answers, and it
also answers when the call fails or after `ASSISTANT_DAILY_LIMIT` model calls in
a day (500 by default). That count lives in `Rails.cache`, so it is as wide as
the cache store: with the default file store it is per machine and starts again
when `tmp/` is cleared, and a store that cannot count allows no model call. The
endpoint is throttled to 12 requests a minute per address, a reply may look at
the workspace once, and the whole call has 30 seconds.

**On-device.** The page asks the browser's built-in model through Chrome's
Prompt API (`app/javascript/controllers/assistant_local_model.js`), which is
Gemini Nano on desktop Chrome. Nothing is sent to the server. Choosing
On-device downloads the model the first time. In a browser without the API the
option is off, and an offline visitor keeps their draft until they reconnect.

**Auto** asks Rails when online and the browser's model when offline or when
Rails cannot be reached.
