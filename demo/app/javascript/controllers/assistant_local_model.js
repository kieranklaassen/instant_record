// The model that runs in the browser: Chrome's built-in Prompt API, which serves
// Gemini Nano from the device. The chat controller knows only these three
// functions, so another in-browser runtime can stand behind them.
const INSTRUCTIONS = "You are the assistant in the InstantRecord demo, a Rails app whose pages keep working offline: " +
  "each write commits to a local SQLite database in the browser, joins an outbox, and syncs to Rails when the connection returns. " +
  "You are running inside the visitor's browser, with no connection to the server. Answer briefly and concretely, for a Rails developer. " +
  "Format with plain paragraphs, \"- \" bullet lists, numbered lists, and fenced code blocks only."

// "unavailable", "downloadable", "downloading" or "available".
export async function availability() {
  try { return await globalThis.LanguageModel.availability() }
  catch { return "unavailable" }
}

// Downloads the model. Chrome starts a download only from a click or a key press.
export async function prepare(onProgress) {
  const session = await globalThis.LanguageModel.create({
    monitor(download) { download.addEventListener("downloadprogress", event => onProgress(event.loaded)) }
  })
  session.destroy()
}

// Answers one prompt, calling onText with the reply so far as it streams.
// history is the conversation's earlier turns as [prompt, reply] pairs. The
// model's context is small, so when the turns don't fit, the oldest half is
// forgotten and the prompt is asked again.
export async function reply(prompt, history, options) {
  for (let turns = history; ; turns = turns.slice(Math.ceil(turns.length / 2))) {
    try { return await ask(prompt, turns, options) }
    catch (error) { if (error.name !== "QuotaExceededError" || !turns.length) throw error }
  }
}

async function ask(prompt, history, { signal, onText }) {
  const session = await globalThis.LanguageModel.create({
    signal,
    initialPrompts: [{ role: "system", content: INSTRUCTIONS },
      ...history.flatMap(([asked, answered]) => [{ role: "user", content: asked }, { role: "assistant", content: answered }])]
  })
  try {
    let text = ""
    for await (const chunk of session.promptStreaming(prompt, { signal })) {
      text += chunk
      onText(text)
    }
    return text
  } finally {
    session.destroy()
  }
}
