require "test_helper"
require "ruby_llm/test_helper"

class Assistant::ReplyTest < ActiveSupport::TestCase
  include RubyLLM::TestHelper

  KEYS = %w[ASSISTANT_MODEL ASSISTANT_DAILY_LIMIT ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY].freeze

  setup do
    @env = ENV.to_h.slice(*KEYS)
    KEYS.each { |key| ENV.delete(key) }
  end

  teardown do
    KEYS.each { |key| ENV.delete(key) }
    ENV.update(@env)
  end

  test "with no provider key the scripted guide answers" do
    reply = Assistant::Reply.call(prompt: "Explain offline sync")
    assert_equal "guide", reply[:engine]
    assert_includes reply[:reply], "worker sends pending mutations"
    assert_nil reply[:model]
  end

  test "with a provider key the model answers, with the earlier turns as context" do
    ENV["ANTHROPIC_API_KEY"] = "test"
    stub_replies "A queue of pending writes."
    history = [["What is an outbox?", "A table of writes Rails has not seen."], ["Why a table?", "It survives a reload."]]

    reply, chats = capture_chats { Assistant::Reply.call(prompt: "Sum that up", history: history) }

    assert_equal({ reply: "A queue of pending writes.", engine: "ruby_llm", model: "claude-haiku-5-5" }, reply)
    sent = chats.sole.messages.reject { |message| message.role == :system }.first(5).map { |message| [message.role, message.content] }
    assert_equal [[:user, "What is an outbox?"], [:assistant, "A table of writes Rails has not seen."],
      [:user, "Why a table?"], [:assistant, "It survives a reload."], [:user, "Sum that up"]], sent
  end

  test "ASSISTANT_MODEL overrides the provider's default" do
    ENV["OPENAI_API_KEY"] = "test"
    ENV["ASSISTANT_MODEL"] = "gpt-5.4-nano"
    stub_replies "Hello"
    assert_equal "gpt-5.4-nano", Assistant::Reply.call(prompt: "Hi")[:model]
  end

  test "each provider's default model is one RubyLLM knows" do
    Assistant::Reply::DEFAULT_MODELS.each_value { |id| assert RubyLLM.models.find(id), id }
  end

  test "a failed model call falls back to the guide" do
    ENV["ANTHROPIC_API_KEY"] = "test"
    [RubyLLM::ServerError.new("down"), Timeout::Error.new("slow")].each do |error|
      stub_replies error
      reply = Assistant::Reply.call(prompt: "Explain offline sync")
      assert_equal "guide", reply[:engine]
      assert_includes reply[:reply], "worker sends pending mutations"
    end
  end

  test "an unknown model, or a model with no key, falls back to the guide" do
    ENV["ASSISTANT_MODEL"] = "no-such-model"
    assert_equal "guide", Assistant::Reply.call(prompt: "Hi")[:engine]
    ENV["ASSISTANT_MODEL"] = "claude-haiku-5-5"
    assert_equal "guide", Assistant::Reply.call(prompt: "Hi")[:engine]
  end

  test "past the daily limit the guide answers without calling the model" do
    ENV["ANTHROPIC_API_KEY"] = "test"
    ENV["ASSISTANT_DAILY_LIMIT"] = "1"
    stub_replies "From the model"
    _, chats = capture_chats do
      with_cache(ActiveSupport::Cache::MemoryStore.new) do
        assert_equal "ruby_llm", Assistant::Reply.call(prompt: "Hi")[:engine]
        assert_equal "guide", Assistant::Reply.call(prompt: "Hi")[:engine]
      end
    end
    assert_equal 1, chats.size
  end

  test "the model can read the workspace through its tool" do
    ENV["ANTHROPIC_API_KEY"] = "test"
    stub_replies tool_call(:workspace_todos), "Counted."
    reply, chats = capture_chats { Assistant::Reply.call(prompt: "Inspect my workspace") }
    assert_equal "Counted.", reply[:reply]
    assert_includes chats.sole.messages.find { |message| message.role == :tool }.content.to_s, Issue.count.to_s
  end

  test "the workspace tool counts the todos" do
    counts = Assistant::WorkspaceTool.new.execute
    assert_equal Issue.count, counts[:total]
    assert_equal Issue.where(state: "done").count, counts[:done]
    assert_equal counts[:total], counts[:open] + counts[:done]
  end

  private

  # Runs the block and returns its value with every chat RubyLLM built in it.
  def capture_chats
    chats = []
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**options| original.call(**options).tap { |chat| chats << chat } }
    [yield, chats]
  ensure
    RubyLLM.define_singleton_method(:chat, original)
  end

  def with_cache(store)
    original = Rails.cache
    Rails.cache = store
    yield
  ensure
    Rails.cache = original
  end
end
