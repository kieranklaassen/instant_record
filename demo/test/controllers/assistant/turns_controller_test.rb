require "test_helper"

module Assistant
  class TurnsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @chat = AssistantChat.create!(id: "chat-test", title: "A test chat")
    end

    test "the page lists the chats and draws the newest turns of the open one" do
      12.times { |i| turn("Question #{i}", reply: "Answer #{i}", created_at: i.minutes.from_now) }

      get assistant_root_url(chat: @chat.id)

      assert_response :success
      assert_select "#relay-chats a[aria-current=page]", text: "A test chat"
      assert_select "#relay-title", text: "A test chat"
      assert_select "#relay-turns .relay-turn", 8
      assert_select "#relay-turns .relay-turn:last-child .relay-user", text: "Question 11"
      assert_select "#relay-older a[href=?]", "/assistant?chat=chat-test&depth=16"
    end

    test "depth draws earlier turns and the fragment is only the live parts" do
      12.times { |i| turn("Question #{i}", reply: "Answer #{i}", created_at: i.minutes.from_now) }

      get assistant_root_url(chat: @chat.id, depth: 16, fragment: 1)

      assert_select "#relay-turns .relay-turn", 12
      assert_select "#relay-older", 0
      assert_select "#relay-chats"
      assert_select "form", 0
    end

    test "a chat with no turns shows the welcome" do
      get assistant_root_url(chat: "not-yet-a-chat")

      assert_response :success
      assert_select "#relay-title", text: "New chat"
      assert_select "#relay-welcome"
      assert_select "input[name='turn[assistant_chat_id]'][value=?]", "not-yet-a-chat"
    end

    test "a question saves a turn, opens its chat and asks the server" do
      assert_enqueued_with(job: Assistant::ReplyJob) do
        post assistant_turns_url, params: { turn: { assistant_chat_id: "chat-new", prompt: "  Explain offline sync  ", engine: "auto" } }
      end

      assert_redirected_to assistant_root_path(chat: "chat-new")
      turn = AssistantTurn.find_by!(assistant_chat_id: "chat-new")
      assert_equal ["Explain offline sync", "", "server"], [turn.prompt, turn.reply, turn.engine]
      assert_equal "Explain offline sync", AssistantChat.find("chat-new").title
    end

    test "a question for the browser's model enqueues nothing and answers with the fragment" do
      assert_no_enqueued_jobs do
        post assistant_turns_url(fragment: 1), params: { turn: { assistant_chat_id: @chat.id, prompt: "What is an outbox?", engine: "local" } }
      end

      assert_response :success
      assert_select ".relay-turn[data-engine=local][data-pending=true] .relay-user", text: "What is an outbox?"
    end

    test "a blank question saves nothing" do
      assert_no_difference -> { AssistantTurn.count } do
        post assistant_turns_url, params: { turn: { assistant_chat_id: @chat.id, prompt: "   " } }
      end
    end

    test "the browser's model saves its reply onto its own turn" do
      asked = turn("What is an outbox?", engine: "local")

      patch assistant_turn_url(asked, fragment: 1), params: { turn: { reply: "A table of writes." } }

      assert_response :success
      assert_equal ["A table of writes.", AssistantTurn::LOCAL_AUTHOR], asked.reload.values_at(:reply, :author)
      assert_select "#turn-#{asked.id}[data-pending=false] .relay-author", text: "On-device model"
    end

    test "a turn that asked the server takes no reply from a browser" do
      asked = turn("What is an outbox?")

      patch assistant_turn_url(asked), params: { turn: { reply: "Not from Rails." } }

      assert_equal "", asked.reload.reply
    end

    test "a reply is drawn as paragraphs, lists and code" do
      turn("Show me", reply: "Intro\n\n- one\n- two\n\n1. first\n2. second\n\n```ruby\nIssue.count\n```\n\n<b>Done</b>")

      get assistant_root_url(chat: @chat.id)

      assert_select ".relay-response ul li", 2
      assert_select ".relay-response ol li", text: "second"
      assert_select ".relay-response pre code", text: "Issue.count"
      assert_select ".relay-response b", 0
      assert_includes response.body, "&lt;b&gt;Done&lt;/b&gt;"
    end

    private

    def turn(prompt, **attributes)
      AssistantTurn.create!(assistant_chat_id: @chat.id, prompt: prompt, **attributes)
    end
  end
end
