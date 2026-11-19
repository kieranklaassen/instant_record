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
    arg = "maya/support/#{@message.id}"
    view = ThreadScreen.new(arg).render.children.sole

    assert_equal ["swift", "ConversationView"], [view.kind, view.text]
    assert_equal({ "thread" => arg, "subject" => "Night shift", "participants" => "rae, theo, maya", "archived" => "" }, strings(view))
    messages = view.children.find { |node| node.kind == "props" }
    assert_equal "messages", messages.id
    assert_equal ["Can we invite them?", "Yes, from Settings.", "I sent the invites."], messages.children.map { |record| strings(record)["body"] }
    assert_equal [["rae", "rae@example.test", ""], ["theo", "", ""], ["maya", "", "true"]], messages.children.map { |record| strings(record).values_at("author", "address", "mine") }
    assert_equal @message.created_at.utc.iso8601(6), strings(messages.children.first)["date"]
  end

  test "the view's archive comes back through perform, and the props then say it is archived" do
    arg = "maya/support/#{@message.id}"

    ThreadScreen.new(arg).perform("archive", strings(ThreadScreen.new(arg).render.children.sole)["thread"])

    assert_equal "true", strings(ThreadScreen.new(arg).render.children.sole)["archived"]
    assert MailEntry.exists?(kind: "archive", parent_id: @message.id, author: "maya")
  end

  test "a conversation from another inbox is not shown" do
    %w[maya/billing jo/support].each do |place|
      root = ThreadScreen.new("#{place}/#{@message.id}").render

      assert_equal %w[text], root.children.first.children.map(&:kind)
    end
  end

  private

  def reply(author, body)
    @support.append!(id: SecureRandom.uuid, author: author, attributes: { kind: "reply", parent_id: @message.id, body: body })
  end

  def strings(node) = node.children.select { |child| child.kind == "prop" }.to_h { |prop| [prop.id, prop.text] }
end
