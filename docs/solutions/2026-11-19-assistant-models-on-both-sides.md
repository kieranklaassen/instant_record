# The Assistant's models, server and browser: what building it corrected

Date: 2026-11-19. Plan: `docs/plans/2026-11-19-001-feat-assistant-ruby-llm-local-model-plan.md`.

## What stands

Online, `Assistant::Reply` asks a model through RubyLLM. Offline, the page asks the browser's built-in model through Chrome's Prompt API (`LanguageModel`). A switch chooses Auto, Server or On-device.

Later the same day the conversations moved out of the page's script and into records (`AssistantChat`, `AssistantTurn`). A question is a write; a `server_only` callback enqueues `Assistant::ReplyJob`, which writes Rails' answer onto the turn, and the browser's model saves its answer onto the turn too. Chats are private to a visitor through the gem's `sync_scope`, which this work added: the browser sends a token, and Rails keeps a scoped model's rows, changes and writes to the token they belong to. The reply endpoint and its history parameters are gone, so the notes below about the endpoint describe the first version. What they taught still holds for the job.

## What we believed, and what was true

- **"Headless Chromium has no `LanguageModel`."** Chromium 157 defines it, reports `downloadable`, "downloads" at once, and answers every prompt by echoing its input, with a context of 1,000 units. A test of "a browser with no model" has to remove `LanguageModel` before the page loads. The echo is still useful: it exercises the real API's shapes (`create` with `initialPrompts` and a `monitor`, `promptStreaming`, an abort signal) that a hand-written stand-in only imitates.
- **"A new session with the whole conversation is fine."** The echo's small context refused the second turn with `QuotaExceededError`. Real Gemini Nano has a few thousand tokens, which a chat reaches too. `assistant_local_model.js` now forgets the oldest half of the turns and asks again.
- **"If a chunk starts with the text so far, the stream is cumulative."** It also holds for a delta stream that repeats a word (`"word "` after `"word "`), and the reply stopped growing. Chrome streams deltas: append them.
- **"Rescuing `RubyLLM::Error` covers a failed call."** `ModelNotFoundError`, `ConfigurationError` and `ToolRoundLimitError` are plain `StandardError`s in RubyLLM 2.2. A mistyped model name would have been a 500.
- **"A tool loop ends by itself."** RubyLLM has no default limit on tool rounds. A prompt that tells the model to keep calling the tool made 61 provider requests from one HTTP request. `with_tool_options(rounds: 2)` allows one useful round: the round that reaches the limit raises instead of asking the model again.
- **"The throttle covers the endpoint."** `req.path == "/assistant/replies"` missed `.json`, a trailing slash and a doubled slash, which all route to the same action.
- **"Clip to 2,000 in JavaScript, validate 2,000 in Ruby."** JavaScript counts UTF-16 units and Ruby counts characters. A `slice` that lands inside an emoji leaves half of it, and Rails refuses the JSON. Clip with `Array.from(text).slice(0, n).join("")`.

## For the next paid endpoint in a demo

The demos answer any origin (`InstantRecord::CORS_HEADERS`), and a turn now reaches Rails through any browser's outbox, so a per-address throttle does not bound spend. What bounds it here: a daily count in `Rails.cache` that fails closed when the store cannot count, a cap on output tokens, a cap on tool rounds, and a deadline on the whole call. The count is only as wide as the cache store.

## Not yet run

A reply from a real provider (no key in a cloud thread) and from the real Gemini Nano (needs desktop Chrome with the model).
