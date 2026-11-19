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

    test "the model is given the chat's earlier answered turns as this visitor sees them, oldest first" do
      turn("First?", reply: "One.", created_at: 3.minutes.ago)
      turn("Unanswered", created_at: 2.minutes.ago)
      turn("Someone else's", reply: "Not yours.", visitor_id: "bob", created_at: 90.seconds.ago)
      turn("Second?", reply: "Two.", visitor_id: "ada", created_at: 1.minute.ago)
      asked = turn("Third?", visitor_id: "ada")
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

    test "a visitor's oldest chats make room, and nobody else's do" do
      kept = Assistant::ReplyJob::KEPT_CHATS
      (kept + 2).times { |i| AssistantChat.create!(id: "ada-#{i}", title: "Chat #{i}", visitor_id: "ada", created_at: i.minutes.ago) }
      oldest = AssistantTurn.create!(assistant_chat_id: "ada-#{kept + 1}", prompt: "Old", reply: "Old.", visitor_id: "ada")
      AssistantChat.create!(id: "bob-old", title: "Bob's", visitor_id: "bob", created_at: 1.day.ago)
      AssistantChat.create!(id: "bob-ancient", title: "Bob's", visitor_id: "bob", created_at: Assistant::ReplyJob::KEPT_FOR.ago - 1.day)

      Assistant::ReplyJob.perform_now(AssistantTurn.create!(assistant_chat_id: "ada-0", prompt: "Explain offline sync", visitor_id: "ada").id)

      assert_equal kept, AssistantChat.where(visitor_id: "ada").count
      assert_not AssistantTurn.exists?(oldest.id)
      assert_equal %w[bob-old chat-test], AssistantChat.where.not(visitor_id: "ada").or(AssistantChat.where(visitor_id: nil)).pluck(:id).sort
    end

    test "Rails' answer is logged for its visitor alone" do
      asked = turn("Explain offline sync", visitor_id: "ada")

      Assistant::ReplyJob.perform_now(asked.id)

      assert_equal "ada", InstantRecord::Change.where(record_id: asked.id).last.scope
    end

    private

    def turn(prompt, **attributes)
      AssistantTurn.create!(assistant_chat_id: @chat.id, prompt: prompt, **attributes)
    end
  end
end
