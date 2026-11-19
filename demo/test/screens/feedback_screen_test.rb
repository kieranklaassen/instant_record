require "test_helper"

class FeedbackScreenTest < ActiveSupport::TestCase
  test "the screen is the app's own form, told who is writing and from which inbox" do
    navigation = FeedbackScreen.new("member" => "maya", "inbox" => "support").render.children.first
    form = navigation.children.first

    assert_equal ["navigation", "Feedback"], [navigation.kind, navigation.props["title"]]
    assert_equal ["swift", "FeedbackForm"], [form.kind, form.text]
    assert_equal [%w[from maya], %w[inbox support]], form.children.map { |prop| [prop.props["name"], prop.text] }
  end
end
