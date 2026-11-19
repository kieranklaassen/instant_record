require "test_helper"

class ThreadScreenTest < ActiveSupport::TestCase
  setup do
    MailEntry.delete_all
    Mailbox.delete_all
    @support = Mailbox.create!(id: "support")
    Mailbox.create!(id: "billing")
    @message = @support.append!(id: SecureRandom.uuid, author: "rae",
      attributes: { kind: "message", address: "rae@example.test", subject: "Night shift", body: "Can we invite them?" })
    travel_to(1.minute.from_now) { reply("theo", "Yes, from Settings.") }
    travel_to(2.minutes.from_now) { reply("maya", "I sent the invites.") }
    @here = { "member" => "maya", "inbox" => "support", "id" => @message.id }
  end

  test "does not inherit from the mailbox" do
    assert_equal InstantRecord::Native::Screen, ThreadScreen.superclass
  end

  test "hands the Swift view the conversation: subject, who is in it, and each message in the order written" do
    view = ThreadScreen.new(@here).render.children.first

    assert_equal ["swift", "ConversationView"], [view.kind, view.text]
    assert_equal({ "subject" => "Night shift", "participants" => "rae, theo, maya", "archived" => "false" }, values(view))
    assert_equal "flag", view.children.find { |node| node.id == "archived" }.kind
    messages = view.children.find { |node| node.kind == "props" }
    assert_equal "messages", messages.id
    assert_equal ["Can we invite them?", "Yes, from Settings.", "I sent the invites."], messages.children.map { |record| values(record)["body"] }
    assert_equal [["rae", "rae@example.test", "false"], ["theo", "", "false"], ["maya", "", "true"]], messages.children.map { |record| values(record).values_at("author", "address", "mine") }
    assert_equal @message.created_at.utc.iso8601(6), values(messages.children.first)["date"]
  end

  test "opening marks the message read for this member, once" do
    assert_difference -> { MailEntry.where(kind: "read", parent_id: @message.id, author: "maya").count }, 1 do
      ThreadScreen.new(@here).perform("open", {})
      ThreadScreen.new(@here).perform("open", {})
    end
    assert_not MailEntry.exists?(kind: "read", author: "theo")
  end

  test "the view's archive comes back through perform, and the props then say it is archived" do
    ThreadScreen.new(@here).perform("archive", {})

    assert_equal "true", values(ThreadScreen.new(@here).render.children.first)["archived"]
    assert MailEntry.exists?(kind: "archive", parent_id: @message.id, author: "maya")
  end

  test "a reply box sits under the conversation" do
    bar = ThreadScreen.new(@here).render.children.last
    field, send = bar.children

    assert_equal "bottom", bar.kind
    assert_equal ["field", "body", "Reply"], [field.kind, field.id, field.props["placeholder"]]
    assert_equal ["button", "Send", "reply"], [send.kind, send.text, send.action]
  end

  test "a reply is stored as typed and shows as this member's" do
    words = "She said \"yes\"\nsee you at the café ☕"

    travel_to(3.minutes.from_now) { ThreadScreen.new(@here).perform("reply", { "body" => "  #{words}\n" }) }

    last = ThreadScreen.new(@here).render.children.first.children.find { |node| node.kind == "props" }.children.last
    assert_equal [words, "maya", "true"], values(last).values_at("body", "author", "mine")
    assert_equal words, MailEntry.find_by(kind: "reply", author: "maya", body: words).body
  end

  test "an empty reply, or one with only spaces, writes nothing" do
    assert_no_difference -> { MailEntry.count } do
      ThreadScreen.new(@here).perform("reply", { "body" => "" })
      ThreadScreen.new(@here).perform("reply", { "body" => " \n\t " })
      ThreadScreen.new(@here).perform("reply", {})
    end
  end

  test "a conversation from another inbox is not shown, and nothing can be done to it" do
    [{ "member" => "maya", "inbox" => "billing" }, { "member" => "jo", "inbox" => "support" }].each do |place|
      there = place.merge("id" => @message.id)

      assert_equal %w[text], ThreadScreen.new(there).render.children.first.children.map(&:kind)
      assert_no_difference -> { MailEntry.count } do
        ThreadScreen.new(there).perform("reply", { "body" => "Hello" })
        ThreadScreen.new(there).perform("archive", {})
        ThreadScreen.new(there).perform("open", {})
      end
    end
  end

  private

  def reply(author, body)
    @support.append!(id: SecureRandom.uuid, author: author, attributes: { kind: "reply", parent_id: @message.id, body: body })
  end

  def values(node) = node.children.reject { |child| child.kind == "props" }.to_h { |child| [child.id, child.text] }
end
