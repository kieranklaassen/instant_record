require "test_helper"

class AssistantRepliesTest < ActionDispatch::IntegrationTest
  test "the server answers workspace prompts with its current issue count" do
    post "/assistant/replies", params: { prompt: "Inspect my workspace" }, as: :json
    assert_response :success
    assert_equal "guide", response.parsed_body.fetch("engine")
    assert_includes response.parsed_body.fetch("reply"), "#{Issue.count} todos"
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "the guide returns the requested response format" do
    { "test plan" => "- Send an item", "trace delivery" => "1. The sender", "show a patch" => "```diff", "compare pagination" => "keyset cursor" }.each do |prompt, snippet|
      post "/assistant/replies", params: { prompt: prompt }, as: :json
      assert_response :success
      assert_includes response.parsed_body.fetch("reply"), snippet
    end
  end

  test "only a nonempty bounded text prompt is accepted" do
    ["", " " * 5, "x" * 8001, ["Explain offline sync"]].each do |invalid|
      post "/assistant/replies", params: { prompt: invalid }, as: :json
      assert_response :unprocessable_entity
    end
  end
end
