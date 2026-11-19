require "test_helper"

module Assistant
  class ReplyJobTest < ActiveJob::TestCase
    setup do
      @chat = AssistantChat.create!(id: "chat-test", title: "A test chat")
    end

    test "a turn that asks the server enqueues a reply, and one for the browser does not" do
      assert_enqueued_with(job: Assistant::ReplyJob) { turn("Explain offline sync") }
      assert_no_enqueued_jobs { turn("Explain offline sync", engine: "local") }
      assert_no_enqueued_jobs { turn("Already answered", reply: "Yes.") }
    end

    test "the job writes Rails' answer onto the turn, where the change log carries it" do
      asked = turn("Explain offline sync")

      assert_difference -> { InstantRecord::Change.count }, 1 do
        Assistant::ReplyJob.perform_now(asked.id)
      end

      asked.reload
      assert_includes asked.reply, "worker sends pending mutations"
      assert_equal "Demo guide", asked.author
    end

    test "the model is given the chat's earlier answered turns, oldest first" do
      turn("First?", reply: "One.", created_at: 3.minutes.ago)
      turn("Unanswered", created_at: 2.minutes.ago)
      turn("Second?", reply: "Two.", created_at: 1.minute.ago)
      asked = turn("Third?")
      asked_with = nil

      original = Assistant::Reply.method(:call)
      Assistant::Reply.define_singleton_method(:call) do |prompt:, history:|
        asked_with = [prompt, history]
        { reply: "Three.", engine: "ruby_llm", model: "a-model" }
      end
      begin
        Assistant::ReplyJob.perform_now(asked.id)
      ensure
        Assistant::Reply.define_singleton_method(:call, original)
      end

      assert_equal ["Third?", [["First?", "One."], ["Second?", "Two."]]], asked_with
      assert_equal ["Three.", "a-model · RubyLLM"], asked.reload.values_at(:reply, :author)
    end

    test "a turn answered or removed in the meantime is left alone" do
      answered = turn("Asked", reply: "Already here.", author: "On-device model")

      Assistant::ReplyJob.perform_now(answered.id)
      Assistant::ReplyJob.perform_now("gone")

      assert_equal "Already here.", answered.reload.reply
    end

    test "the oldest visitor chats make room, and the examples stay" do
      AssistantChat.create!(id: AssistantChat::EXAMPLES.first, title: "An example", created_at: 1.year.ago)
      (Assistant::ReplyJob::KEPT_CHATS + 2).times { |i| AssistantChat.create!(id: "visitor-#{i}", title: "Chat #{i}", created_at: i.minutes.ago) }
      oldest = AssistantTurn.create!(assistant_chat_id: "visitor-#{Assistant::ReplyJob::KEPT_CHATS + 1}", prompt: "Old", reply: "Old.")

      Assistant::ReplyJob.perform_now(turn("Explain offline sync").id)

      assert_equal Assistant::ReplyJob::KEPT_CHATS, AssistantChat.where("id LIKE 'visitor-%' OR id = 'chat-test'").count
      assert AssistantChat.exists?(AssistantChat::EXAMPLES.first)
      assert_not AssistantTurn.exists?(oldest.id)
    end

    private

    def turn(prompt, **attributes)
      AssistantTurn.create!(assistant_chat_id: @chat.id, prompt: prompt, **attributes)
    end
  end
end
