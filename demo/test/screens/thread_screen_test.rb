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
  end

  test "hands the Swift view the conversation: subject, who is in it, and each message in the order written" do
    view = ThreadScreen.new(at("maya/support")).render.children.first

    assert_equal ["swift", "ConversationView"], [view.kind, view.text]
    assert_equal({ "subject" => "Night shift", "participants" => "rae, theo, maya", "archived" => "false" }, strings(view))
    messages = view.children.find { |node| node.kind == "props" }
    assert_equal "messages", messages.props["name"]
    assert_equal ["Can we invite them?", "Yes, from Settings.", "I sent the invites."], messages.children.map { |record| strings(record)["body"] }
    assert_equal [["rae", "rae@example.test", "false"], ["theo", "", "false"], ["maya", "", "true"]], messages.children.map { |record| strings(record).values_at("author", "address", "mine") }
    assert_equal @message.created_at.utc.iso8601(6), strings(messages.children.first)["date"]
    assert_equal %w[string string date string bool], messages.children.first.children.map { |prop| prop.props["type"] }
  end

  test "the view's archive comes back through perform, and the props then say it is archived" do
    screen = -> { ThreadScreen.new(at("maya/support")) }

    screen.call.perform("archive", {}, {})

    assert_equal "true", strings(screen.call.render.children.first)["archived"]
    assert MailEntry.exists?(kind: "archive", parent_id: @message.id, author: "maya")
  end

  test "opening the conversation marks it read for this member, once" do
    assert_difference -> { MailEntry.where(kind: "read", parent_id: @message.id, author: "theo").count }, 1 do
      2.times { ThreadScreen.new(at("theo/support")).perform("open", {}, {}) }
    end
  end

  test "a reply box sits under the conversation, and what is typed in it becomes a reply by this member" do
    field, send = ThreadScreen.new(at("maya/support")).render.children.last.children

    assert_equal ["field", "body", "Reply", "true"], [field.kind, *field.props.values_at("name", "label", "multiline")]
    assert_equal ["button", "reply", "send"], [send.kind, send.action, send.props["image"]]

    assert_difference -> { MailEntry.where(kind: "reply", parent_id: @message.id, author: "maya").count }, 1 do
      ThreadScreen.new(at("maya/support")).perform("reply", {}, { "body" => "  On it, \"today\".\nThanks  " })
    end
    said = ThreadScreen.new(at("maya/support")).render.children.first.children.find { |node| node.kind == "props" }.children.find { |record| strings(record)["body"].start_with?("On it") }
    assert_equal ["maya", "On it, \"today\".\nThanks", "true"], strings(said).values_at("author", "body", "mine")
  end

  test "a reply with nothing in it, or to a conversation that is not here, writes nothing" do
    assert_no_difference -> { MailEntry.count } do
      ThreadScreen.new(at("maya/support")).perform("reply", {}, { "body" => "  \n " })
      ThreadScreen.new(at("maya/support")).perform("reply", {}, {})
      ThreadScreen.new(at("jo/support")).perform("reply", {}, { "body" => "Hello" })
      ThreadScreen.new(at("maya/billing")).perform("open", {}, {})
    end
  end

  test "a conversation from another inbox is not shown" do
    %w[maya/billing jo/support].each do |place|
      root = ThreadScreen.new(at(place)).render

      assert_equal %w[text], root.children.first.children.map(&:kind)
    end
  end

  private

  def reply(author, body)
    @support.append!(id: SecureRandom.uuid, author: author, attributes: { kind: "reply", parent_id: @message.id, body: body })
  end

  def at(place)
    member, inbox = place.split("/")
    { "member" => member, "inbox" => inbox, "thread" => @message.id }
  end

  def strings(node) = node.children.select { |child| child.kind == "prop" }.to_h { |prop| [prop.props["name"], prop.text] }
end
