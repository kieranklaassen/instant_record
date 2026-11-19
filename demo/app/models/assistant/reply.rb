module Assistant
  # One answer for the Assistant demo. With a provider key in the environment it
  # asks a model through RubyLLM; otherwise, and whenever that call fails or the
  # day's budget is spent, the scripted Guide answers.
  class Reply
    # The small model of whichever provider has a key. ASSISTANT_MODEL overrides.
    DEFAULT_MODELS = {
      "ANTHROPIC_API_KEY" => "claude-haiku-5-5",
      "OPENAI_API_KEY" => "gpt-5.4-mini",
      "GEMINI_API_KEY" => "gemini-3.1-flash-lite"
    }.freeze
    MAX_OUTPUT_TOKENS = 600
    # One look at the workspace, then an answer: a second round of tool calls ends the reply.
    TOOL_ROUNDS = 2
    # Seconds for the whole reply, every round and retry included.
    DEADLINE = 30
    DAILY_LIMIT = 500

    INSTRUCTIONS = <<~TEXT.squish
      You are the assistant in the InstantRecord demo, a Rails app whose pages keep
      working offline: each write commits to a local SQLite database in the browser,
      joins an outbox, and syncs to Rails and PostgreSQL when the connection returns.
      Answer briefly and concretely, for a Rails developer. Format with plain
      paragraphs, "- " bullet lists, numbered lists, and fenced code blocks only.
      Use the workspace_todos tool when asked about the workspace or its todos.
    TEXT

    def self.call(prompt:, history: [])
      new(prompt, history).call
    end

    def self.model
      ENV["ASSISTANT_MODEL"].presence || DEFAULT_MODELS.find { |key, _| ENV[key].present? }&.last
    end

    def initialize(prompt, history)
      @prompt = prompt
      @history = history
    end

    def call
      model = self.class.model
      content = ask(model) if model && within_budget?
      if content.present?
        { reply: content, engine: "ruby_llm", model: model }
      else
        { reply: Guide.reply(@prompt), engine: "guide" }
      end
    end

    private

    # Anything a provider call can raise ends in the guide: RubyLLM's unknown
    # model and missing key errors are not RubyLLM::Errors.
    def ask(model)
      chat = RubyLLM.chat(model: model)
        .with_instructions(INSTRUCTIONS)
        .with_max_output_tokens(MAX_OUTPUT_TOKENS)
        .with_tools(WorkspaceTool)
        .with_tool_options(rounds: TOOL_ROUNDS)
      @history.each do |prompt, reply|
        chat.add_message(role: :user, content: prompt)
        chat.add_message(role: :assistant, content: reply)
      end
      Timeout.timeout(DEADLINE) { chat.ask(@prompt) }.content.to_s.strip
    rescue StandardError => error
      Rails.logger.warn("[assistant] #{error.class}: answering from the guide")
      nil
    end

    # A turn reaches Rails from any browser's outbox, so no per-address throttle
    # bounds what visitors spend. This count does. A cache store that cannot count
    # allows nothing, and the count is as wide as the store: one machine for a file store.
    def within_budget?
      limit = ENV.fetch("ASSISTANT_DAILY_LIMIT", DAILY_LIMIT).to_i
      count = Rails.cache.increment("assistant/replies/#{Time.now.utc.to_date}", 1, expires_in: 2.days)
      count.present? && count <= limit
    end
  end
end
