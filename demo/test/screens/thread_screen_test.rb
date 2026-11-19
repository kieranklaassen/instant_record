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

  test "shows the message and then its replies in the order they were written" do
    navigation = ThreadScreen.new("maya/support/#{@message.id}").render.children.first

    assert_equal "Night shift", navigation.props["title"]
    sections = navigation.children.first.children
    assert_equal ["Can we invite them?", "Yes, from Settings.", "I sent the invites."], sections.map { |section| section.children.first.children.last.text }
  end

  test "offers archive until the conversation is archived" do
    arg = "maya/support/#{@message.id}"
    button = toolbar(arg).children.sole

    assert_equal ["button", "archive", arg], [button.kind, button.action, button.arg]

    ThreadScreen.new(arg).perform(button.action, button.arg)

    assert_empty toolbar(arg).children
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

  def toolbar(arg)
    ThreadScreen.new(arg).render.children.first.children.find { |node| node.kind == "toolbar" }
  end
end
